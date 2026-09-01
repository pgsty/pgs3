#[pgrx::pg_schema]
mod pgs3 {
    use pgrx::prelude::*;
    use sha2::{Digest, Sha256};

    /// Compute the server-trusted digest used by the SQL storage layer.
    #[pg_extern(immutable, strict, parallel_safe)]
    fn sha256(value: &[u8]) -> Vec<u8> {
        Sha256::digest(value).to_vec()
    }

    /// Start (or reuse) a launcher for the caller's current database.
    #[pg_extern(security_definer)]
    #[search_path(pg_catalog, pgs3)]
    fn start() -> bool {
        crate::workers::launcher::start_dynamic()
    }

    /// Stop the launcher and its pool for the caller's current database.
    #[pg_extern(security_definer)]
    #[search_path(pg_catalog, pgs3)]
    fn stop() -> bool {
        crate::workers::launcher::stop_dynamic()
    }
}

pgrx::extension_sql_file!(
    "../sql/worker_runtime.sql",
    name = "pgs3_worker_runtime",
    requires = ["pgs3_bootstrap"]
);

// Rust-backed functions are emitted after the bootstrap SQL.  Keep worker
// lifecycle control out of PUBLIC's default function privileges in a finalize
// block so operators must grant it deliberately.
pgrx::extension_sql!(
    r#"
REVOKE ALL ON FUNCTION pgs3.start() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.stop() FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.hash_upload_part(uuid, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgs3.hash_blob_sequence(bytea[]) FROM PUBLIC;
"#,
    name = "lock_down_worker_control",
    finalize
);
