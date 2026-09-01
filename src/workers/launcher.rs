use pgrx::bgworkers::{
    BackgroundWorker, BackgroundWorkerBuilder, BgWorkerStartTime, DynamicBackgroundWorker,
    SignalWakeFlags,
};
use pgrx::datum::DatumWithOid;
use pgrx::prelude::*;
use std::time::{Duration, Instant};

use super::{GC_TYPE, HTTP_TYPE, LAUNCHER_TYPE, pack_child_argument};

const CONTROL_LOCK: i64 = 8_096_713_151_153_001;
const RECONCILE_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum LauncherMode {
    Static = 0,
    Dynamic = 1,
}

impl LauncherMode {
    fn from_argument(argument: pg_sys::Datum) -> Self {
        if argument.value() == Self::Dynamic as usize {
            Self::Dynamic
        } else {
            Self::Static
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Static => "static",
            Self::Dynamic => "dynamic",
        }
    }
}

fn launcher_builder(
    database: &str,
    mode: LauncherMode,
    restart_time: Option<Duration>,
) -> BackgroundWorkerBuilder {
    BackgroundWorkerBuilder::new(LAUNCHER_TYPE)
        .set_type(LAUNCHER_TYPE)
        .set_library("pgs3")
        .set_function("pgs3_launcher_main")
        .set_extra(database)
        .set_argument(Some(pg_sys::Datum::from(mode as i32)))
        .enable_spi_access()
        // ConsistentState permits a launcher and future read-only HTTP routes
        // on a hot standby.  GC/state writes explicitly skip recovery.
        .set_start_time(BgWorkerStartTime::ConsistentState)
        .set_restart_time(restart_time)
}

pub(crate) fn register_static() {
    launcher_builder(
        &crate::config::target_database(),
        LauncherMode::Static,
        Some(Duration::from_secs(1)),
    )
    .load();
}

/// Start or reactivate the pool in the caller's current database.  The
/// advisory transaction lock closes the only registration race; liveness is
/// derived from pg_stat_activity rather than a backend-local worker handle.
pub(crate) fn start_dynamic() -> bool {
    let Some(database) = current_database() else {
        warning!("pgs3 could not determine current_database()");
        return false;
    };
    if !control_lock() {
        return false;
    }

    if let Some(other_database) = conflicting_database() {
        warning!(
            "pgs3 cannot start in {database}: an HTTP pool is already active in {other_database}"
        );
        return false;
    }

    if let Some((pid, mode)) = active_launcher() {
        let mode = mode.unwrap_or_else(|| "static".to_owned());
        if set_existing_launcher_desired(pid, &mode, true) {
            log!("pgs3 launcher already active in {database} with pid {pid}");
            return true;
        }
        return false;
    }

    let builder = launcher_builder(&database, LauncherMode::Dynamic, None)
        .set_notify_pid(unsafe { pg_sys::MyProcPid });
    let worker = match builder.load_dynamic() {
        Ok(worker) => worker,
        Err(_) => {
            warning!("pgs3 could not register a dynamic launcher for {database}");
            return false;
        }
    };

    match worker.wait_for_startup() {
        Ok(pid) => {
            // The handle is intentionally not retained.  Dynamic worker handles
            // are process-private; state rows plus validated PIDs make stop()
            // work from every SQL session.
            // A SQL statement keeps one MVCC snapshot, so this backend cannot
            // observe child state rows committed while start() is still
            // running.  Successful launcher startup is the synchronous
            // boundary; callers can observe pool convergence via pgs3.stats.
            log!("pgs3 dynamic launcher started in {database} with pid {pid}");
            true
        }
        Err(status) => {
            warning!("pgs3 dynamic launcher did not start: {status:?}");
            false
        }
    }
}

/// Stop the pool in the caller's current database.  Repeating stop() after all
/// workers have left is success, not an error.
pub(crate) fn stop_dynamic() -> bool {
    if current_database().is_none() || !control_lock() {
        return false;
    }

    let launcher = active_launcher();
    let children_stopped = terminate_live_children();
    let launcher_stopped = match launcher.as_ref() {
        Some((pid, Some(mode))) if mode == LauncherMode::Dynamic.as_str() => {
            terminate_pid(*pid, 4_000)
        }
        Some((_pid, _)) => true, // A static launcher remains registered but idle.
        None => true,
    };
    let state_updated = mark_pool_stopped(
        launcher
            .as_ref()
            .and_then(|(pid, mode)| mode.as_deref().map(|mode| (*pid, mode))),
    );

    children_stopped && launcher_stopped && state_updated
}

fn current_database() -> Option<String> {
    Spi::connect(|client| {
        client
            .select("SELECT pg_catalog.current_database()::text", Some(1), &[])?
            .first()
            .get_one::<String>()
    })
    .ok()
    .flatten()
}

fn control_lock() -> bool {
    Spi::run(&format!(
        "SELECT pg_catalog.pg_advisory_xact_lock({CONTROL_LOCK})"
    ))
    .is_ok()
}

fn active_launcher() -> Option<(i32, Option<String>)> {
    Spi::connect(|client| {
        client
            .select(
                r#"SELECT a.pid, s.mode
                   FROM pg_catalog.pg_stat_activity AS a
                   LEFT JOIN pgs3.worker_state AS s
                     ON s.worker_kind = 'launcher'
                    AND s.worker_slot = 0
                    AND s.pid = a.pid
                  WHERE a.datname = pg_catalog.current_database()
                    AND a.backend_type = 'pgs3 launcher'
                  ORDER BY a.backend_start
                  LIMIT 1"#,
                Some(1),
                &[],
            )?
            .first()
            .get_two::<i32, String>()
    })
    .ok()
    .and_then(|(pid, mode)| pid.map(|pid| (pid, mode)))
}

fn conflicting_database() -> Option<String> {
    Spi::connect(|client| {
        client
            .select(
                r#"SELECT a.datname::text
                     FROM pg_catalog.pg_stat_activity AS a
                    WHERE a.backend_type = 'pgs3 http'
                      AND a.datname IS DISTINCT FROM pg_catalog.current_database()
                    ORDER BY a.backend_start
                    LIMIT 1"#,
                Some(1),
                &[],
            )?
            .first()
            .get_one::<String>()
    })
    .ok()
    .flatten()
}

fn set_existing_launcher_desired(pid: i32, mode: &str, desired: bool) -> bool {
    let args: [DatumWithOid<'_>; 3] = [pid.into(), mode.to_owned().into(), desired.into()];
    Spi::run_with_args(
        r#"INSERT INTO pgs3.worker_state (
             worker_kind, worker_slot, pid, launcher_pid, mode, desired, status,
             started_at, heartbeat_at
         ) VALUES (
             'launcher', 0, $1, $1, $2, $3,
             CASE WHEN $3 THEN 'running' ELSE 'idle' END,
             pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp()
         )
         ON CONFLICT (worker_kind, worker_slot) DO UPDATE
            SET pid = EXCLUDED.pid, launcher_pid = EXCLUDED.launcher_pid,
                mode = EXCLUDED.mode, desired = EXCLUDED.desired,
                status = EXCLUDED.status, heartbeat_at = EXCLUDED.heartbeat_at,
                stopped_at = NULL, last_error = NULL"#,
        &args,
    )
    .is_ok()
}

fn terminate_live_children() -> bool {
    Spi::get_one::<bool>(
        r#"SELECT COALESCE(
             bool_and(pg_catalog.pg_terminate_backend(a.pid, 4000::bigint)), true
         )
           FROM pg_catalog.pg_stat_activity AS a
          WHERE a.datname = pg_catalog.current_database()
            AND a.backend_type IN ('pgs3 http', 'pgs3 gc')"#,
    )
    .ok()
    .flatten()
    .unwrap_or(false)
}

fn terminate_pid(pid: i32, timeout_ms: i64) -> bool {
    let args: [DatumWithOid<'_>; 2] = [pid.into(), timeout_ms.into()];
    Spi::get_one_with_args::<bool>("SELECT pg_catalog.pg_terminate_backend($1, $2)", &args)
        .ok()
        .flatten()
        .unwrap_or(false)
}

fn mark_pool_stopped(launcher: Option<(i32, &str)>) -> bool {
    let (launcher_pid, launcher_mode) = launcher
        .map(|(pid, mode)| (Some(pid), Some(mode.to_owned())))
        .unwrap_or((None, None));
    let args: [DatumWithOid<'_>; 2] = [launcher_pid.into(), launcher_mode.into()];
    if Spi::run(
        r#"UPDATE pgs3.worker_state
              SET desired = false, status = 'stopped',
                  stopped_at = pg_catalog.clock_timestamp(),
                  heartbeat_at = pg_catalog.clock_timestamp()
            WHERE worker_kind IN ('http', 'gc')"#,
    )
    .is_err()
    {
        return false;
    }
    Spi::run_with_args(
        r#"INSERT INTO pgs3.worker_state (
             worker_kind, worker_slot, pid, launcher_pid, mode, desired, status,
             heartbeat_at, stopped_at
         ) VALUES (
             'launcher', 0, $1, $1, $2, false,
             CASE WHEN $2 = 'static' THEN 'idle' ELSE 'stopped' END,
             pg_catalog.clock_timestamp(),
             CASE WHEN $2 = 'static' THEN NULL ELSE pg_catalog.clock_timestamp() END
         )
         ON CONFLICT (worker_kind, worker_slot) DO UPDATE
            SET desired = false,
                status = CASE WHEN pgs3.worker_state.mode = 'static'
                              THEN 'idle' ELSE 'stopped' END,
                heartbeat_at = pg_catalog.clock_timestamp(),
                stopped_at = CASE WHEN pgs3.worker_state.mode = 'static'
                                  THEN NULL ELSE pg_catalog.clock_timestamp() END"#,
        &args,
    )
    .is_ok()
}

struct ManagedWorker {
    kind: &'static str,
    slot: i32,
    pid: i32,
    handle: DynamicBackgroundWorker,
}

struct WorkerPool {
    database: String,
    launcher_pid: i32,
    http: Vec<ManagedWorker>,
    gc: Option<ManagedWorker>,
    server_role: String,
}

impl WorkerPool {
    fn new(database: String, launcher_pid: i32) -> Self {
        Self {
            database,
            launcher_pid,
            http: Vec::new(),
            gc: None,
            server_role: crate::config::server_role(),
        }
    }

    fn reconcile(&mut self, desired_http: usize, writable: bool) {
        self.remove_stopped();

        let configured_role = crate::config::server_role();
        if configured_role != self.server_role {
            self.stop_http(true);
            self.server_role = configured_role;
        }

        while let Some(index) = self
            .http
            .iter()
            .position(|worker| worker.slot < 0 || worker.slot as usize >= desired_http)
        {
            let worker = self.http.swap_remove(index);
            stop_managed(worker, self.launcher_pid, false);
        }

        if !server_role_ready(&self.server_role) {
            // Role attributes, memberships, and ACLs are part of the request
            // security boundary.  Drift must stop already-running listeners,
            // not merely prevent replacement workers from spawning.
            self.stop_http(true);
            let message = format!(
                "pgs3.server_role {} is missing, privileged, or lacks runtime grants",
                self.server_role
            );
            for slot in 0..desired_http {
                record_child_error("http", slot as i32, self.launcher_pid, &message);
            }
            warning!("{message}");
        } else {
            for slot in 0..desired_http {
                if !self.http.iter().any(|worker| worker.slot == slot as i32)
                    && let Some(worker) = spawn_http(&self.database, self.launcher_pid, slot as i32)
                {
                    self.http.push(worker);
                }
            }
        }

        if writable {
            if self.gc.is_none() {
                self.gc = spawn_gc(&self.database, self.launcher_pid);
            }
        } else if let Some(worker) = self.gc.take() {
            // A standby serves only HTTP read routes.  A GC worker has no
            // useful recovery-safe work and must never be started there.
            stop_managed(worker, self.launcher_pid, false);
        }
    }

    fn remove_stopped(&mut self) {
        let mut index = 0;
        while index < self.http.len() {
            if self.http[index].handle.pid().is_ok() {
                index += 1;
            } else {
                let worker = self.http.swap_remove(index);
                record_child_error(
                    "http",
                    worker.slot,
                    self.launcher_pid,
                    "HTTP worker exited; launcher will replace it",
                );
            }
        }
        if self
            .gc
            .as_ref()
            .is_some_and(|worker| worker.handle.pid().is_err())
        {
            let worker = self.gc.take().expect("checked as some");
            record_child_error(
                "gc",
                worker.slot,
                self.launcher_pid,
                "GC worker exited; launcher will replace it",
            );
        }
    }

    fn stop_http(&mut self, desired_after_stop: bool) {
        for worker in self.http.drain(..) {
            stop_managed(worker, self.launcher_pid, desired_after_stop);
        }
    }

    fn stop_all(&mut self) {
        self.stop_http(false);
        if let Some(worker) = self.gc.take() {
            stop_managed(worker, self.launcher_pid, false);
        }
    }
}

fn child_builder(
    name: &str,
    worker_type: &str,
    function: &str,
    database: &str,
    launcher_pid: i32,
    slot: i32,
) -> BackgroundWorkerBuilder {
    BackgroundWorkerBuilder::new(name)
        .set_type(worker_type)
        .set_library("pgs3")
        .set_function(function)
        .set_extra(database)
        .set_argument(Some(pack_child_argument(launcher_pid, slot)))
        .enable_spi_access()
        .set_start_time(BgWorkerStartTime::ConsistentState)
        .set_restart_time(None)
        .set_notify_pid(unsafe { pg_sys::MyProcPid })
}

fn spawn_http(database: &str, launcher_pid: i32, slot: i32) -> Option<ManagedWorker> {
    let name = format!("pgs3 http {slot}");
    spawn_child(
        child_builder(
            &name,
            HTTP_TYPE,
            "pgs3_http_main",
            database,
            launcher_pid,
            slot,
        ),
        "http",
        launcher_pid,
        slot,
    )
}

fn spawn_gc(database: &str, launcher_pid: i32) -> Option<ManagedWorker> {
    spawn_child(
        child_builder(
            "pgs3 gc 0",
            GC_TYPE,
            "pgs3_gc_main",
            database,
            launcher_pid,
            0,
        ),
        "gc",
        launcher_pid,
        0,
    )
}

fn spawn_child(
    builder: BackgroundWorkerBuilder,
    kind: &'static str,
    launcher_pid: i32,
    slot: i32,
) -> Option<ManagedWorker> {
    let worker = match builder.load_dynamic() {
        Ok(worker) => worker,
        Err(_) => {
            record_child_error(
                kind,
                slot,
                launcher_pid,
                "dynamic worker registration failed",
            );
            return None;
        }
    };
    match worker.wait_for_startup() {
        Ok(pid) => {
            record_child_starting(kind, slot, pid, launcher_pid);
            Some(ManagedWorker {
                kind,
                slot,
                pid,
                handle: worker,
            })
        }
        Err(status) => {
            record_child_error(
                kind,
                slot,
                launcher_pid,
                &format!("dynamic worker startup failed: {status:?}"),
            );
            None
        }
    }
}

fn stop_managed(worker: ManagedWorker, launcher_pid: i32, desired_after_stop: bool) {
    let ManagedWorker {
        kind,
        slot,
        pid,
        handle,
    } = worker;
    match handle.terminate().wait_for_shutdown() {
        Ok(()) => log!("pgs3 worker slot {slot} pid {pid} stopped"),
        Err(status) => {
            warning!("pgs3 worker slot {slot} pid {pid} did not stop cleanly: {status:?}")
        }
    }
    record_child_stopped(kind, slot, launcher_pid, desired_after_stop);
}

fn server_role_ready(role: &str) -> bool {
    let args: [DatumWithOid<'_>; 1] = [role.to_owned().into()];
    BackgroundWorker::transaction(|| {
        Spi::connect(|client| {
            client
                .select(
                    r#"SELECT EXISTS (
                         SELECT 1
                           FROM pg_catalog.pg_roles AS r
                          WHERE r.rolname = $1
                            AND NOT r.rolcanlogin
                            AND NOT r.rolinherit
                            AND NOT r.rolsuper
                            AND NOT r.rolcreatedb
                            AND NOT r.rolcreaterole
                            AND NOT r.rolreplication
                            AND NOT r.rolbypassrls
                            AND NOT EXISTS (
                                SELECT 1
                                  FROM pg_catalog.pg_auth_members AS m
                                 WHERE m.member = r.oid
                                   AND (m.admin_option OR m.inherit_option)
                            )
                            AND NOT EXISTS (
                                SELECT 1
                                  FROM pg_catalog.pg_auth_members AS m
                                 WHERE m.roleid = r.oid
                            )
                            AND pg_catalog.has_database_privilege(
                                r.rolname, pg_catalog.current_database(), 'CONNECT'
                            )
                            AND pg_catalog.has_schema_privilege(r.rolname, 'pgs3', 'USAGE')
                            AND pg_catalog.has_table_privilege(
                                r.rolname, 'pgs3.credential', 'SELECT'
                            )
                            AND pg_catalog.has_function_privilege(
                                r.rolname,
                                'pgs3._worker_set_state(text,integer,integer,text,text,integer,text)',
                                'EXECUTE'
                            )
                            AND pg_catalog.has_function_privilege(
                                r.rolname,
                                'pgs3._worker_add_metric(text,integer,text,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint,bigint)',
                                'EXECUTE'
                            )
                            AND pg_catalog.has_function_privilege(
                                r.rolname,
                                'pgs3._worker_set_actor(name)',
                                'EXECUTE'
                            )
                            AND pg_catalog.has_function_privilege(
                                r.rolname,
                                'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)',
                                'EXECUTE'
                            )
                            AND pg_catalog.has_function_privilege(
                                r.rolname,
                                'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])',
                                'EXECUTE'
                            )
                     )"#,
                    Some(1),
                    &args,
                )?
                .first()
                .get_one::<bool>()
        })
        .ok()
        .flatten()
        .unwrap_or(false)
    })
}

fn cleanup_orphan_children() {
    let stopped = BackgroundWorker::transaction(|| {
        Spi::get_one::<bool>(
            r#"SELECT COALESCE(
                 bool_and(pg_catalog.pg_terminate_backend(a.pid, 2000::bigint)), true
             )
               FROM pg_catalog.pg_stat_activity AS a
              WHERE a.datname = pg_catalog.current_database()
                AND a.backend_type IN ('pgs3 http', 'pgs3 gc')"#,
        )
        .ok()
        .flatten()
        .unwrap_or(false)
    });
    if !stopped {
        warning!("pgs3 launcher could not stop every orphan worker");
    }
}

fn claim_launcher_state(mode: LauncherMode, desired: bool) -> Option<bool> {
    let pid = unsafe { pg_sys::MyProcPid };
    let args: [DatumWithOid<'_>; 4] = [
        pid.into(),
        mode.as_str().to_owned().into(),
        desired.into(),
        (if desired { "running" } else { "idle" }).to_owned().into(),
    ];
    BackgroundWorker::transaction(|| {
        Spi::get_one_with_args::<bool>(
            r#"INSERT INTO pgs3.worker_state (
                 worker_kind, worker_slot, pid, launcher_pid, mode, desired, status,
                 started_at, heartbeat_at, stopped_at, last_error
             ) VALUES (
                 'launcher', 0, $1, $1, $2, $3, $4,
                 pg_catalog.clock_timestamp(), pg_catalog.clock_timestamp(), NULL, NULL
             )
             ON CONFLICT (worker_kind, worker_slot) DO UPDATE
                SET pid = EXCLUDED.pid, launcher_pid = EXCLUDED.launcher_pid,
                    mode = EXCLUDED.mode,
                    desired = CASE
                        WHEN pgs3.worker_state.pid = EXCLUDED.pid
                        THEN pgs3.worker_state.desired
                        ELSE EXCLUDED.desired
                    END,
                    status = CASE
                        WHEN CASE
                            WHEN pgs3.worker_state.pid = EXCLUDED.pid
                            THEN pgs3.worker_state.desired
                            ELSE EXCLUDED.desired
                        END
                        THEN 'running' ELSE 'idle'
                    END,
                    started_at = EXCLUDED.started_at,
                    heartbeat_at = EXCLUDED.heartbeat_at, stopped_at = NULL,
                    last_error = NULL
             RETURNING desired"#,
            &args,
        )
        .ok()
        .flatten()
    })
}

fn heartbeat_launcher(pid: i32, status: &str) -> Option<bool> {
    let args: [DatumWithOid<'_>; 2] = [pid.into(), status.to_owned().into()];
    BackgroundWorker::transaction(|| {
        Spi::get_one_with_args::<bool>(
            r#"UPDATE pgs3.worker_state
                SET status = CASE WHEN desired THEN $2 ELSE 'idle' END,
                    heartbeat_at = pg_catalog.clock_timestamp()
              WHERE worker_kind = 'launcher' AND worker_slot = 0 AND pid = $1
          RETURNING desired"#,
            &args,
        )
        .ok()
        .flatten()
    })
}

fn set_static_desired_from_guc(pid: i32) {
    let args: [DatumWithOid<'_>; 2] = [pid.into(), crate::config::enabled().into()];
    let _ = BackgroundWorker::transaction(|| {
        Spi::run_with_args(
            r#"UPDATE pgs3.worker_state
                SET desired = $2,
                    status = CASE WHEN $2 THEN 'running' ELSE 'idle' END,
                    heartbeat_at = pg_catalog.clock_timestamp()
              WHERE worker_kind = 'launcher' AND worker_slot = 0 AND pid = $1"#,
            &args,
        )
    });
}

fn record_child_starting(kind: &str, slot: i32, pid: i32, launcher_pid: i32) {
    if !super::runtime_is_writable() {
        return;
    }
    let args: [DatumWithOid<'_>; 4] = [
        kind.to_owned().into(),
        slot.into(),
        pid.into(),
        launcher_pid.into(),
    ];
    let _ = BackgroundWorker::transaction(|| {
        Spi::run_with_args(
            r#"INSERT INTO pgs3.worker_state (
                 worker_kind, worker_slot, pid, launcher_pid, desired, status, heartbeat_at
             ) VALUES ($1, $2, $3, $4, true, 'starting', pg_catalog.clock_timestamp())
             ON CONFLICT (worker_kind, worker_slot) DO UPDATE
                SET pid = EXCLUDED.pid, launcher_pid = EXCLUDED.launcher_pid,
                    desired = true,
                    status = CASE
                        WHEN pgs3.worker_state.pid = EXCLUDED.pid
                         AND pgs3.worker_state.status IN ('running', 'idle')
                        THEN pgs3.worker_state.status ELSE 'starting' END,
                    heartbeat_at = pg_catalog.clock_timestamp(),
                    stopped_at = NULL, last_error = NULL"#,
            &args,
        )
    });
}

fn record_child_error(kind: &str, slot: i32, launcher_pid: i32, message: &str) {
    if !super::runtime_is_writable() {
        return;
    }
    let args: [DatumWithOid<'_>; 4] = [
        kind.to_owned().into(),
        slot.into(),
        launcher_pid.into(),
        message.chars().take(1024).collect::<String>().into(),
    ];
    let _ = BackgroundWorker::transaction(|| {
        Spi::run_with_args(
            r#"INSERT INTO pgs3.worker_state (
                 worker_kind, worker_slot, launcher_pid, desired, status,
                 heartbeat_at, last_error
             ) VALUES ($1, $2, $3, true, 'error', pg_catalog.clock_timestamp(), $4)
             ON CONFLICT (worker_kind, worker_slot) DO UPDATE
                SET pid = NULL, launcher_pid = EXCLUDED.launcher_pid, desired = true,
                    status = 'error', heartbeat_at = EXCLUDED.heartbeat_at,
                    stopped_at = NULL, last_error = EXCLUDED.last_error"#,
            &args,
        )
    });
}

fn record_child_stopped(kind: &str, slot: i32, launcher_pid: i32, desired: bool) {
    if !super::runtime_is_writable() {
        return;
    }
    let args: [DatumWithOid<'_>; 4] = [
        kind.to_owned().into(),
        slot.into(),
        launcher_pid.into(),
        desired.into(),
    ];
    let _ = BackgroundWorker::transaction(|| {
        Spi::run_with_args(
            r#"UPDATE pgs3.worker_state
                  SET desired = $4, status = 'stopped',
                      heartbeat_at = pg_catalog.clock_timestamp(),
                      stopped_at = pg_catalog.clock_timestamp()
                WHERE worker_kind = $1 AND worker_slot = $2 AND launcher_pid = $3"#,
            &args,
        )
    });
}

fn mark_launcher_stopped(pid: i32) {
    let args: [DatumWithOid<'_>; 1] = [pid.into()];
    let _ = BackgroundWorker::transaction(|| {
        Spi::run_with_args(
            r#"UPDATE pgs3.worker_state
                SET desired = false, status = 'stopped',
                    heartbeat_at = pg_catalog.clock_timestamp(),
                    stopped_at = pg_catalog.clock_timestamp()
              WHERE worker_kind = 'launcher' AND worker_slot = 0 AND pid = $1"#,
            &args,
        )
    });
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pgs3_launcher_main(argument: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);

    let mode = LauncherMode::from_argument(argument);
    let database = BackgroundWorker::get_extra().to_owned();
    BackgroundWorker::connect_worker_to_spi(Some(&database), None);
    let launcher_pid = unsafe { pg_sys::MyProcPid };
    log!(
        "pgs3 {} launcher connected to database {} with pid {}",
        mode.as_str(),
        database,
        launcher_pid
    );

    let mut schema_ready = false;
    let mut state_owned = false;
    let mut desired = mode == LauncherMode::Dynamic || crate::config::enabled();
    let mut pool = WorkerPool::new(database, launcher_pid);
    let mut next_reconcile = Instant::now();

    loop {
        if BackgroundWorker::sighup_received() {
            super::reload_configuration();
            if mode == LauncherMode::Static {
                desired = crate::config::enabled();
                if state_owned && super::runtime_is_writable() {
                    set_static_desired_from_guc(launcher_pid);
                }
            }
            next_reconcile = Instant::now();
        }

        if !schema_ready && super::runtime_schema_ready() {
            schema_ready = true;
            next_reconcile = Instant::now();
        }

        if schema_ready && Instant::now() >= next_reconcile {
            let writable = super::runtime_is_writable();
            if writable && !state_owned {
                cleanup_orphan_children();
                if let Some(database_desired) = claim_launcher_state(mode, desired) {
                    desired = database_desired;
                    state_owned = true;
                }
            }

            if writable && state_owned {
                match heartbeat_launcher(launcher_pid, "running") {
                    Some(database_desired) => desired = database_desired,
                    None => {
                        // Another validated launcher replaced this row.  Leaving
                        // is safer than two SO_REUSEPORT pools in one database.
                        warning!("pgs3 launcher state ownership was lost; exiting");
                        break;
                    }
                }
            }

            if desired {
                pool.reconcile(crate::config::workers(), writable);
            } else {
                pool.stop_all();
            }
            next_reconcile = Instant::now() + RECONCILE_INTERVAL;
        }

        if !BackgroundWorker::wait_latch(Some(Duration::from_millis(250))) {
            break;
        }
    }

    pool.stop_all();
    if state_owned && super::runtime_is_writable() {
        mark_launcher_stopped(launcher_pid);
    }
    log!("pgs3 launcher pid {launcher_pid} exiting");
}

#[cfg(test)]
mod tests {
    use super::{LauncherMode, pg_sys};

    #[test]
    fn launcher_mode_argument_is_fail_closed_to_static() {
        assert_eq!(
            LauncherMode::from_argument(pg_sys::Datum::from(1_i32)),
            LauncherMode::Dynamic
        );
        assert_eq!(
            LauncherMode::from_argument(pg_sys::Datum::from(99_i32)),
            LauncherMode::Static
        );
    }
}
