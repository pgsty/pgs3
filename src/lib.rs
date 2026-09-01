use pgrx::prelude::*;

mod api;
mod config;
mod hash;
mod protocol;
pub(crate) mod s3;
mod workers;

::pgrx::pg_module_magic!();

// The handwritten semantic layer is the install script's bootstrap section.
// It creates the pgs3 schema before pgrx emits the Rust-backed functions below.
pgrx::extension_sql_file!("../sql/bootstrap.sql", name = "pgs3_bootstrap", bootstrap);

#[allow(non_snake_case)]
#[pg_guard]
pub extern "C-unwind" fn _PG_init() {
    config::init();

    // Static workers may only be registered while PostgreSQL is processing
    // shared_preload_libraries.  CREATE EXTENSION loads the same library later,
    // so keep the dynamic/manual path separate.
    let loading_from_shared_preload =
        unsafe { pgrx::pg_sys::process_shared_preload_libraries_in_progress };
    if loading_from_shared_preload && config::enabled() {
        workers::launcher::register_static();
    }
}
/// Hooks used by `cargo pgrx test`.
#[cfg(test)]
pub mod pg_test {
    pub fn setup(_options: Vec<&str>) {}

    #[must_use]
    pub fn postgresql_conf_options() -> Vec<&'static str> {
        Vec::new()
    }
}
