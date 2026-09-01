//! Periodic, bounded garbage-collection worker.

use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use pgrx::prelude::*;
use std::time::{Duration, Instant};

use super::{MetricDelta, WorkerState, unpack_child_argument};

// GC policy remains internal until its lease/batch knobs have a documented GUC
// contract.  Each function already claims at most 1,000 rows with SKIP LOCKED.
const GC_INTERVAL: Duration = Duration::from_secs(60);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(1);

fn run_pending_gc(slot: i32) {
    if !super::runtime_is_writable() {
        return;
    }
    let started = Instant::now();
    let result = BackgroundWorker::transaction(|| {
        Spi::get_one::<i64>("SELECT pgs3.gc_pending_uploads(INTERVAL '24 hours', 1000)")
            .ok()
            .flatten()
    });
    let mut delta = MetricDelta::default();
    delta.observe_completion(result.is_none(), 0, 0, started.elapsed());
    let _ = super::add_worker_metric("gc", slot, "gc_pending_uploads", delta);
}

fn run_blob_gc(slot: i32) {
    if !super::runtime_is_writable() {
        return;
    }
    let started = Instant::now();
    let result = BackgroundWorker::transaction(|| {
        Spi::get_one::<i64>("SELECT pgs3.gc_blobs(1000)")
            .ok()
            .flatten()
    });
    let mut delta = MetricDelta::default();
    delta.observe_completion(result.is_none(), 0, 0, started.elapsed());
    let _ = super::add_worker_metric("gc", slot, "gc_blobs", delta);
}

fn record_state(slot: i32, launcher_pid: i32, status: &str, error: Option<&str>) {
    let _ = super::set_worker_state(WorkerState {
        kind: "gc",
        slot,
        launcher_pid,
        status,
        listen_addr: None,
        port: None,
        error,
    });
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pgs3_gc_main(argument: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    let (launcher_pid, slot) = unpack_child_argument(argument);
    let database = BackgroundWorker::get_extra().to_owned();
    BackgroundWorker::connect_worker_to_spi(Some(&database), None);
    if !super::runtime_schema_ready() {
        warning!("pgs3 GC worker found no runtime schema in {database}");
        return;
    }

    record_state(slot, launcher_pid, "idle", None);
    log!("pgs3 GC worker connected to database {database}");
    let mut next_gc = Instant::now() + GC_INTERVAL;
    let mut next_heartbeat = Instant::now();

    loop {
        if BackgroundWorker::sighup_received() {
            super::reload_configuration();
        }

        let now = Instant::now();
        if now >= next_gc {
            record_state(slot, launcher_pid, "running", None);
            run_pending_gc(slot);
            // Use a separate transaction so a blob batch never shares locks or
            // failure state with pending-upload reclamation.
            run_blob_gc(slot);
            record_state(slot, launcher_pid, "idle", None);
            next_gc = Instant::now() + GC_INTERVAL;
        }
        if now >= next_heartbeat {
            record_state(slot, launcher_pid, "idle", None);
            next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
        }

        if !BackgroundWorker::wait_latch(Some(Duration::from_millis(250))) {
            break;
        }
    }

    record_state(slot, launcher_pid, "stopped", None);
    log!("pgs3 GC worker exiting");
}

#[cfg(test)]
mod tests {
    use super::GC_INTERVAL;

    #[test]
    fn gc_schedule_is_not_a_busy_loop() {
        assert!(GC_INTERVAL.as_secs() >= 1);
        assert!(GC_INTERVAL.as_secs() <= 24 * 60 * 60);
    }
}
