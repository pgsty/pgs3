//! PostgreSQL background-worker boundaries.
//!
//! Every function in this module which touches PostgreSQL is called only from a
//! background worker's process-main thread.  Socket multiplexing is likewise
//! single threaded; no PostgreSQL pointer, memory context, or SPI connection is
//! sent to another Rust thread.

pub(crate) mod gc;
pub(crate) mod http;
pub(crate) mod launcher;

use pgrx::bgworkers::BackgroundWorker;
use pgrx::datum::DatumWithOid;
use pgrx::prelude::*;
use std::ffi::CString;
use std::time::Duration;

pub(crate) const LAUNCHER_TYPE: &str = "pgs3 launcher";
pub(crate) const HTTP_TYPE: &str = "pgs3 http";
pub(crate) const GC_TYPE: &str = "pgs3 gc";

/// Connect an HTTP worker as the restricted service role.  pgrx 0.19.2's
/// `connect_worker_to_spi` wrapper always passes flags=0, which would require a
/// LOGIN role.  PostgreSQL 17/18 expose BGWORKER_BYPASS_ROLELOGINCHECK so the
/// internal-only service identity can remain NOLOGIN.
pub(crate) fn connect_worker_to_spi_as_service(database: &str, role: &str) -> Result<(), String> {
    let database = CString::new(database).map_err(|_| "database name contains NUL".to_owned())?;
    let role = CString::new(role).map_err(|_| "server role contains NUL".to_owned())?;

    #[cfg(feature = "pg16")]
    {
        let _ = (database, role);
        return Err("a NOLOGIN pgs3.server_role requires PostgreSQL 17 or newer".to_owned());
    }

    #[cfg(any(feature = "pg17", feature = "pg18"))]
    unsafe {
        pgrx::pg_sys::BackgroundWorkerInitializeConnection(
            database.as_ptr(),
            role.as_ptr(),
            pgrx::pg_sys::BGWORKER_BYPASS_ROLELOGINCHECK,
        );
    }
    Ok(())
}

pub(crate) fn reload_configuration() {
    unsafe {
        pgrx::pg_sys::ProcessConfigFile(pgrx::pg_sys::GucContext::PGC_SIGHUP);
    }
}

/// The runtime tables arrive with CREATE EXTENSION, which can happen after a
/// preloaded launcher has already connected.  Probe with to_regclass so an
/// absent extension is an idle state rather than a crash loop.
pub(crate) fn runtime_schema_ready() -> bool {
    BackgroundWorker::transaction(|| {
        // pgrx 0.19's Spi::get_one() is implemented with SpiClient::update(),
        // which calls GetCurrentTransactionId() before executing even a plain
        // SELECT.  That is fatal during recovery.  Keep runtime probes on the
        // genuinely read-only SPI path so the launcher and HTTP workers can
        // start on a hot standby without trying to allocate an XID.
        Spi::connect(|client| {
            client
                .select(
                    r#"SELECT pg_catalog.to_regclass('pgs3.worker_state') IS NOT NULL
                         AND pg_catalog.to_regprocedure(
                             'pgs3._worker_set_state(text,integer,integer,text,text,integer,text)'
                         ) IS NOT NULL
                         AND pg_catalog.to_regprocedure(
                             'pgs3._worker_set_actor(name)'
                         ) IS NOT NULL
                         AND pg_catalog.to_regprocedure(
                             'pgs3._worker_put_chunk(name,text,text,uuid,integer,bytea,bytea)'
                         ) IS NOT NULL
                         AND pg_catalog.to_regprocedure(
                             'pgs3._worker_complete_upload(name,text,text,uuid,bytea,bytea,text,bigint,bytea[],bigint[])'
                         ) IS NOT NULL"#,
                    Some(1),
                    &[],
                )?
                .first()
                .get_one::<bool>()
        })
        .ok()
        .flatten()
        .unwrap_or(false)
    })
}

/// A hot standby can serve future read routes, but neither state rows nor
/// counters may turn a read into a write.  Promotion is detected on the next
/// heartbeat because this probe is intentionally not cached.
pub(crate) fn runtime_is_writable() -> bool {
    BackgroundWorker::transaction(|| {
        Spi::connect(|client| {
            client
                .select("SELECT NOT pg_catalog.pg_is_in_recovery()", Some(1), &[])?
                .first()
                .get_one::<bool>()
        })
        .ok()
        .flatten()
        .unwrap_or(false)
    })
}

pub(crate) struct WorkerState<'a> {
    pub kind: &'a str,
    pub slot: i32,
    pub launcher_pid: i32,
    pub status: &'a str,
    pub listen_addr: Option<&'a str>,
    pub port: Option<i32>,
    pub error: Option<&'a str>,
}

pub(crate) fn set_worker_state(state: WorkerState<'_>) -> bool {
    if !runtime_is_writable() {
        return true;
    }
    BackgroundWorker::transaction(|| {
        let args: [DatumWithOid<'_>; 7] = [
            state.kind.to_owned().into(),
            state.slot.into(),
            state.launcher_pid.into(),
            state.status.to_owned().into(),
            state.listen_addr.map(str::to_owned).into(),
            state.port.into(),
            state.error.map(str::to_owned).into(),
        ];
        Spi::run_with_args(
            "SELECT pgs3._worker_set_state($1, $2, $3, $4, $5, $6, $7)",
            &args,
        )
        .is_ok()
    })
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) struct MetricDelta {
    pub requests: i64,
    pub errors: i64,
    pub bytes_in: i64,
    pub bytes_out: i64,
    pub in_flight_delta: i64,
    pub latency_us: i64,
    pub latency_le_1ms: i64,
    pub latency_le_5ms: i64,
    pub latency_le_10ms: i64,
    pub latency_le_50ms: i64,
    pub latency_le_100ms: i64,
    pub latency_le_500ms: i64,
    pub latency_le_1s: i64,
}

impl MetricDelta {
    pub(crate) fn is_empty(self) -> bool {
        self == Self::default()
    }

    /// Record one connection entering this bounded operation bucket.  The
    /// database applies this as a signed gauge delta rather than a cumulative
    /// counter, so a later completion can return the gauge to zero.
    pub(crate) fn begin_in_flight(&mut self) {
        self.in_flight_delta = self.in_flight_delta.saturating_add(1);
    }

    /// Record one connection leaving this bounded operation bucket.  A negative
    /// buffered delta is intentional when an earlier positive delta has already
    /// been flushed; SQL clamps the materialized gauge at zero.
    pub(crate) fn end_in_flight(&mut self) {
        self.in_flight_delta = self.in_flight_delta.saturating_sub(1);
    }

    pub(crate) fn observe_completion(
        &mut self,
        is_error: bool,
        bytes_in: usize,
        bytes_out: usize,
        elapsed: Duration,
    ) {
        let latency_us = i64::try_from(elapsed.as_micros()).unwrap_or(i64::MAX);
        self.requests = self.requests.saturating_add(1);
        self.errors = self.errors.saturating_add(i64::from(is_error));
        self.bytes_in = self
            .bytes_in
            .saturating_add(i64::try_from(bytes_in).unwrap_or(i64::MAX));
        self.bytes_out = self
            .bytes_out
            .saturating_add(i64::try_from(bytes_out).unwrap_or(i64::MAX));
        self.latency_us = self.latency_us.saturating_add(latency_us);
        self.latency_le_1ms = self
            .latency_le_1ms
            .saturating_add(i64::from(latency_us <= 1_000));
        self.latency_le_5ms = self
            .latency_le_5ms
            .saturating_add(i64::from(latency_us <= 5_000));
        self.latency_le_10ms = self
            .latency_le_10ms
            .saturating_add(i64::from(latency_us <= 10_000));
        self.latency_le_50ms = self
            .latency_le_50ms
            .saturating_add(i64::from(latency_us <= 50_000));
        self.latency_le_100ms = self
            .latency_le_100ms
            .saturating_add(i64::from(latency_us <= 100_000));
        self.latency_le_500ms = self
            .latency_le_500ms
            .saturating_add(i64::from(latency_us <= 500_000));
        self.latency_le_1s = self
            .latency_le_1s
            .saturating_add(i64::from(latency_us <= 1_000_000));
    }
}

pub(crate) fn add_worker_metric(
    kind: &str,
    slot: i32,
    operation: &str,
    delta: MetricDelta,
) -> bool {
    if delta.is_empty() || !runtime_is_writable() {
        return true;
    }
    BackgroundWorker::transaction(|| {
        let args: [DatumWithOid<'_>; 16] = [
            kind.to_owned().into(),
            slot.into(),
            operation.to_owned().into(),
            delta.requests.into(),
            delta.errors.into(),
            delta.bytes_in.into(),
            delta.bytes_out.into(),
            delta.in_flight_delta.into(),
            delta.latency_us.into(),
            delta.latency_le_1ms.into(),
            delta.latency_le_5ms.into(),
            delta.latency_le_10ms.into(),
            delta.latency_le_50ms.into(),
            delta.latency_le_100ms.into(),
            delta.latency_le_500ms.into(),
            delta.latency_le_1s.into(),
        ];
        Spi::run_with_args(
            "SELECT pgs3._worker_add_metric(\
                $1, $2, $3, $4, $5, $6, $7, $8, $9,\
                $10, $11, $12, $13, $14, $15, $16\
            )",
            &args,
        )
        .is_ok()
    })
}

/// `bgw_main_arg` is a Datum passed by value.  Pack the registering launcher
/// PID and the stable worker slot into it; PostgreSQL's supported pgrx targets
/// are 64-bit, so no pointer crosses the process boundary.
pub(crate) fn pack_child_argument(launcher_pid: i32, slot: i32) -> pg_sys::Datum {
    let packed = (u64::from(launcher_pid as u32) << 32) | u64::from(slot as u32);
    pg_sys::Datum::from(packed as usize)
}

pub(crate) fn unpack_child_argument(argument: pg_sys::Datum) -> (i32, i32) {
    let packed = argument.value() as u64;
    ((packed >> 32) as u32 as i32, packed as u32 as i32)
}

#[cfg(test)]
mod tests {
    use super::{MetricDelta, pack_child_argument, unpack_child_argument};
    use std::time::Duration;

    #[test]
    fn child_argument_round_trips_pid_and_slot() {
        for (pid, slot) in [(1, 0), (42_001, 63), (i32::MAX, i32::MAX)] {
            assert_eq!(
                unpack_child_argument(pack_child_argument(pid, slot)),
                (pid, slot)
            );
        }
    }

    #[test]
    fn metric_delta_tracks_gauge_completion_and_cumulative_histogram() {
        let mut delta = MetricDelta::default();
        delta.begin_in_flight();
        delta.observe_completion(true, 17, 29, Duration::from_micros(7_500));
        delta.end_in_flight();

        assert_eq!(delta.in_flight_delta, 0);
        assert_eq!(delta.requests, 1);
        assert_eq!(delta.errors, 1);
        assert_eq!(delta.bytes_in, 17);
        assert_eq!(delta.bytes_out, 29);
        assert_eq!(delta.latency_us, 7_500);
        assert_eq!(delta.latency_le_1ms, 0);
        assert_eq!(delta.latency_le_5ms, 0);
        assert_eq!(delta.latency_le_10ms, 1);
        assert_eq!(delta.latency_le_50ms, 1);
        assert_eq!(delta.latency_le_100ms, 1);
        assert_eq!(delta.latency_le_500ms, 1);
        assert_eq!(delta.latency_le_1s, 1);
    }

    #[test]
    fn metric_gauge_delta_can_cross_flush_boundaries() {
        let mut started = MetricDelta::default();
        started.begin_in_flight();
        assert_eq!(started.in_flight_delta, 1);

        let mut completed = MetricDelta::default();
        completed.end_in_flight();
        assert_eq!(completed.in_flight_delta, -1);
    }
}
