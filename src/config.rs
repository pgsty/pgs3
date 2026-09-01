use pgrx::guc::{GucContext, GucFlags, GucRegistry, GucSetting};
use std::ffi::CString;

static ENABLED: GucSetting<bool> = GucSetting::<bool>::new(false);
static WORKERS: GucSetting<i32> = GucSetting::<i32>::new(4);
static LISTEN_ADDR: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"127.0.0.1"));
static PORT: GucSetting<i32> = GucSetting::<i32>::new(9000);
static INLINE_THRESHOLD: GucSetting<i32> = GucSetting::<i32>::new(64 * 1024);
static CHUNK_SIZE: GucSetting<i32> = GucSetting::<i32>::new(4 * 1024 * 1024);
static STATEMENT_TIMEOUT_MS: GucSetting<i32> = GucSetting::<i32>::new(30_000);
static TARGET_DATABASE: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"postgres"));
static SERVER_ROLE: GucSetting<Option<CString>> =
    GucSetting::<Option<CString>>::new(Some(c"pgs3_server"));

pub(crate) fn init() {
    GucRegistry::define_bool_guc(
        c"pgs3.enabled",
        c"Start pgs3 automatically when it is preloaded.",
        c"Registers the pgs3 launcher during shared_preload_libraries processing.",
        &ENABLED,
        GucContext::Sighup,
        GucFlags::default(),
    );
    GucRegistry::define_int_guc(
        c"pgs3.workers",
        c"Number of HTTP background workers.",
        c"Desired size of the SO_REUSEPORT HTTP worker pool.",
        &WORKERS,
        1,
        64,
        GucContext::Sighup,
        GucFlags::default(),
    );
    GucRegistry::define_string_guc(
        c"pgs3.listen_addr",
        c"Address on which pgs3 listens.",
        c"IPv4 or IPv6 address used by each pgs3 HTTP worker.",
        &LISTEN_ADDR,
        GucContext::Sighup,
        GucFlags::default(),
    );
    GucRegistry::define_int_guc(
        c"pgs3.port",
        c"TCP port on which pgs3 listens.",
        c"TCP port shared by the pgs3 HTTP worker pool.",
        &PORT,
        1,
        65_535,
        GucContext::Sighup,
        GucFlags::default(),
    );
    GucRegistry::define_int_guc(
        c"pgs3.inline_threshold",
        c"Largest object stored inline.",
        c"Objects larger than this many bytes use content-addressed chunks.",
        &INLINE_THRESHOLD,
        0,
        1024 * 1024 * 1024,
        GucContext::Sighup,
        GucFlags::UNIT_BYTE,
    );
    GucRegistry::define_int_guc(
        c"pgs3.chunk_size",
        c"Size of content-addressed object chunks.",
        c"Chunk size in bytes for objects that exceed pgs3.inline_threshold.",
        &CHUNK_SIZE,
        64 * 1024,
        16 * 1024 * 1024,
        GucContext::Sighup,
        GucFlags::UNIT_BYTE,
    );
    GucRegistry::define_int_guc(
        c"pgs3.statement_timeout_ms",
        c"Statement timeout for one S3 request.",
        c"Maximum PostgreSQL statement duration for an HTTP request.",
        &STATEMENT_TIMEOUT_MS,
        1,
        3_600_000,
        GucContext::Sighup,
        GucFlags::UNIT_MS,
    );
    GucRegistry::define_string_guc(
        c"pgs3.target_database",
        c"Database served by the pgs3 launcher.",
        c"Database to which the launcher and HTTP workers connect.",
        &TARGET_DATABASE,
        GucContext::Sighup,
        GucFlags::default(),
    );
    GucRegistry::define_string_guc(
        c"pgs3.server_role",
        c"Role used by pgs3 HTTP background workers.",
        c"Must be a non-superuser, non-BYPASSRLS role allowed to SET ROLE to credential roles.",
        &SERVER_ROLE,
        GucContext::Sighup,
        GucFlags::default(),
    );
}

pub(crate) fn enabled() -> bool {
    ENABLED.get()
}

pub(crate) fn target_database() -> String {
    string_value(&TARGET_DATABASE, "postgres")
}

pub(crate) fn workers() -> usize {
    // PostgreSQL enforces the GUC's 1..=64 range before exposing the value.
    WORKERS.get() as usize
}

pub(crate) fn listen_addr() -> String {
    string_value(&LISTEN_ADDR, "127.0.0.1")
}

pub(crate) fn port() -> u16 {
    PORT.get() as u16
}

pub(crate) fn statement_timeout_ms() -> i32 {
    STATEMENT_TIMEOUT_MS.get()
}

pub(crate) fn inline_threshold_bytes() -> usize {
    // The registered GUC range is 0..=1 GiB and therefore fits usize on every
    // PostgreSQL 17/18 platform supported by pgrx.
    INLINE_THRESHOLD.get().max(0) as usize
}

pub(crate) fn chunk_size_bytes() -> usize {
    // PostgreSQL enforces the registered 64 KiB..=16 MiB range before the
    // worker snapshots this SIGHUP value for a newly accepted upload.
    CHUNK_SIZE.get() as usize
}

pub(crate) fn server_role() -> String {
    string_value(&SERVER_ROLE, "pgs3_server")
}

fn string_value(setting: &GucSetting<Option<CString>>, fallback: &str) -> String {
    setting
        .get()
        .and_then(|value| value.into_string().ok())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| fallback.to_owned())
}
