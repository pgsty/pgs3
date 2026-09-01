#![allow(clippy::too_many_arguments)]

use std::panic::{RefUnwindSafe, UnwindSafe};

use pgrx::bgworkers::BackgroundWorker;
use pgrx::datum::DatumWithOid;
use pgrx::pg_sys::panic::CaughtError;
use pgrx::prelude::*;

use super::route::{ListParams, VersionListParams};
use super::types::S3Error;

const SERVER_REQUEST_CONTEXT_SQL: &str = "SELECT pg_catalog.set_config( \
            'statement_timeout', \
            pg_catalog.current_setting('pgs3.statement_timeout_ms'), \
            true \
        ), pg_catalog.set_config( \
            'lock_timeout', \
            pg_catalog.current_setting('pgs3.statement_timeout_ms'), \
            true \
        )";
const TENANT_REQUEST_CONTEXT_SQL: &str = "SELECT pg_catalog.set_config( \
            'statement_timeout', \
            pg_catalog.current_setting('pgs3.statement_timeout_ms'), \
            true \
        ), pg_catalog.set_config( \
            'lock_timeout', \
            pg_catalog.current_setting('pgs3.statement_timeout_ms'), \
            true \
        ), pg_catalog.set_config('role', $1, true)";

// utils/timeout.h has kept STATEMENT_TIMEOUT at enum value 3 across supported
// PostgreSQL 17 and 18. pgrx does not currently expose the timeout API, so keep
// this narrow FFI boundary beside the only caller. These functions are invoked
// only by a connected background worker on its PostgreSQL main thread.
const STATEMENT_TIMEOUT_ID: std::ffi::c_int = 3;

unsafe extern "C" {
    fn enable_timeout_after(id: std::ffi::c_int, delay_ms: std::ffi::c_int);
    fn disable_timeout(id: std::ffi::c_int, keep_indicator: bool);
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Credential {
    pub secret: String,
    pub role: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct BucketRecord {
    pub name: String,
    pub owner: String,
    pub created_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ObjectRecord {
    pub bucket: String,
    pub key: String,
    pub version_id: i64,
    pub size: i64,
    pub etag: String,
    pub sha256: Vec<u8>,
    pub content_type: Option<String>,
    pub meta_json: String,
    pub created_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ObjectData {
    pub info: ObjectRecord,
    pub body: Vec<u8>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DeleteMarkerRecord {
    pub version_id: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DeleteRecord {
    pub key: String,
    pub version_id: i64,
    pub delete_marker: bool,
    pub deleted: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DeleteTarget {
    pub key: String,
    pub version_id: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ListRecord {
    pub key: Option<String>,
    pub common_prefix: Option<String>,
    pub version_id: Option<i64>,
    pub size: Option<i64>,
    pub etag: Option<String>,
    pub last_modified_ms: Option<i64>,
    pub continuation_token: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct VersionRecord {
    pub key: Option<String>,
    pub common_prefix: Option<String>,
    pub version_id: Option<i64>,
    pub is_latest: Option<bool>,
    pub delete_marker: Option<bool>,
    pub size: Option<i64>,
    pub etag: Option<String>,
    pub last_modified_ms: Option<i64>,
    pub next_key_marker: Option<String>,
    pub next_version_id_marker: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct PartRecord {
    pub part_number: i32,
    pub size: i64,
    pub etag: String,
    pub sha256: Vec<u8>,
    pub completed_ms: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ChunkRecord {
    pub blob_id: Vec<u8>,
    pub size: i64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct DbError {
    pub message: String,
    pub sqlstate: Option<String>,
    pub detail: Option<String>,
}

impl DbError {
    fn spi(error: pgrx::spi::Error) -> Self {
        Self {
            message: format!("SPI failure: {error}"),
            sqlstate: None,
            detail: None,
        }
    }

    fn internal(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
            sqlstate: None,
            detail: None,
        }
    }

    pub(crate) fn to_s3(&self) -> S3Error {
        super::service::map_database_error(
            self.sqlstate.as_deref(),
            self.detail.as_deref(),
            &self.message,
        )
    }
}

pub(crate) trait Database {
    fn lookup_credential(&mut self, access_key: &str) -> Result<Option<Credential>, DbError>;
    fn list_buckets(&mut self, role: &str) -> Result<Vec<BucketRecord>, DbError>;
    fn create_bucket(&mut self, role: &str, bucket: &str, region: &str) -> Result<(), DbError>;
    fn delete_bucket(&mut self, role: &str, bucket: &str) -> Result<(), DbError>;
    fn head_bucket(&mut self, role: &str, bucket: &str) -> Result<(), DbError>;
    fn bucket_location(&mut self, role: &str, bucket: &str) -> Result<String, DbError>;
    fn put_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        body: &[u8],
        content_type: &str,
        meta_json: &str,
        if_none_match: Option<&str>,
        if_match: Option<&str>,
        expected_sha256: Option<&[u8]>,
    ) -> Result<ObjectRecord, DbError>;
    fn head_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: Option<i64>,
    ) -> Result<ObjectRecord, DbError>;
    fn current_delete_marker(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
    ) -> Result<Option<DeleteMarkerRecord>, DbError>;
    fn get_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: Option<i64>,
    ) -> Result<ObjectData, DbError>;
    fn get_range(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: i64,
        start: i64,
        end: i64,
    ) -> Result<Vec<u8>, DbError>;
    fn delete_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: Option<i64>,
    ) -> Result<DeleteRecord, DbError>;
    fn delete_many(
        &mut self,
        role: &str,
        bucket: &str,
        objects: &[DeleteTarget],
    ) -> Result<Vec<Result<DeleteRecord, DbError>>, DbError>;
    fn copy_object(
        &mut self,
        role: &str,
        source_bucket: &str,
        source_key: &str,
        destination_bucket: &str,
        destination_key: &str,
        source_version_id: Option<i64>,
        content_type: Option<&str>,
        meta_json: Option<&str>,
        if_none_match: Option<&str>,
        if_match: Option<&str>,
        source_if_match: Option<&str>,
    ) -> Result<ObjectRecord, DbError>;
    fn restore_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: i64,
        if_match: Option<&str>,
    ) -> Result<ObjectRecord, DbError>;
    fn list_objects(
        &mut self,
        role: &str,
        bucket: &str,
        params: &ListParams,
        v2: bool,
    ) -> Result<Vec<ListRecord>, DbError>;
    fn list_versions(
        &mut self,
        role: &str,
        bucket: &str,
        params: &VersionListParams,
    ) -> Result<Vec<VersionRecord>, DbError>;
    fn begin_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        content_type: &str,
        meta_json: &str,
        multipart: bool,
        if_none_match: Option<&str>,
        if_match: Option<&str>,
        expected_sha256: Option<&[u8]>,
    ) -> Result<String, DbError>;
    fn renew_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        require_multipart: bool,
    ) -> Result<(), DbError>;
    fn put_chunk(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        seq: i32,
        data: &[u8],
        part_number: i32,
    ) -> Result<(), DbError>;
    fn put_chunk_sealed(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        seq: i32,
        data: &[u8],
        server_sha256: &[u8],
    ) -> Result<ChunkRecord, DbError>;
    fn complete_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        expected_sha256: Option<&[u8]>,
    ) -> Result<ObjectRecord, DbError>;
    fn complete_upload_sealed(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        expected_sha256: Option<&[u8]>,
        server_sha256: &[u8],
        server_md5: &str,
        server_size: i64,
        chunk_blob_ids: &[Vec<u8>],
        chunk_sizes: &[i64],
    ) -> Result<ObjectRecord, DbError>;
    fn finish_upload_sealed(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        expected_sha256: Option<&[u8]>,
        server_sha256: &[u8],
        server_md5: &str,
        server_size: i64,
        chunk_blob_ids: &[Vec<u8>],
        chunk_sizes: &[i64],
        final_seq: i32,
        final_data: &[u8],
        final_sha256: &[u8],
    ) -> Result<ObjectRecord, DbError>;
    fn abort_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        multipart: bool,
    ) -> Result<(), DbError>;
    fn begin_part(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        part_number: i32,
    ) -> Result<(), DbError>;
    fn abort_part(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        part_number: i32,
    ) -> Result<(), DbError>;
    fn complete_part(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        part_number: i32,
        expected_sha256: Option<&[u8]>,
    ) -> Result<PartRecord, DbError>;
    fn list_parts(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
    ) -> Result<Vec<PartRecord>, DbError>;
    fn multipart_checksum_algorithm(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
    ) -> Result<Option<String>, DbError>;
    fn complete_multipart(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        parts: &[i32],
        etags: &[String],
        expected_sha256: Option<&[u8]>,
        part_sha256s: Option<&[Vec<u8>]>,
        composite_sha256: Option<&str>,
    ) -> Result<ObjectRecord, DbError>;
}

#[derive(Clone, Debug, Default)]
pub(crate) struct PgDatabase;

impl PgDatabase {
    pub(crate) fn new() -> Self {
        Self
    }

    fn transaction<T, F>(&self, body: F) -> Result<T, DbError>
    where
        F: FnOnce() -> Result<T, DbError> + UnwindSafe + RefUnwindSafe,
    {
        let timeout_ms = crate::config::statement_timeout_ms().max(1);
        pgrx::pg_sys::PgTryBuilder::new(|| {
            // SPI calls issued directly by a background worker have no frontend
            // statement boundary, so SET LOCAL alone does not arm PostgreSQL's
            // statement timer. Arm the registered core handler only after the
            // PgTryBuilder error boundary exists, and disarm it before leaving.
            unsafe {
                disable_timeout(STATEMENT_TIMEOUT_ID, false);
                enable_timeout_after(STATEMENT_TIMEOUT_ID, timeout_ms);
            }
            let result = BackgroundWorker::transaction(body);
            unsafe {
                disable_timeout(STATEMENT_TIMEOUT_ID, false);
            }
            result
        })
        .catch_others(|cause| {
            // A timeout ERROR longjmps past the normal disarm point.
            unsafe {
                disable_timeout(STATEMENT_TIMEOUT_ID, false);
            }
            let (message, sqlstate, detail) = caught_error(&cause);
            // A PostgreSQL ERROR bypasses BackgroundWorker::transaction's
            // normal PopActiveSnapshot/commit tail.  Abort performs the
            // required transaction and snapshot cleanup before the socket
            // loop handles another request.
            unsafe { pgrx::pg_sys::AbortCurrentTransaction() };
            Err(DbError {
                message,
                sqlstate,
                detail,
            })
        })
        .execute()
    }

    /// Run one bounded request transaction. Authentication uses `None` to stay
    /// as the server role; a tenant role is applied transaction-locally only
    /// after the signature has been verified.
    fn with_request_context<T, F>(
        &self,
        role: Option<&str>,
        writable: bool,
        body: F,
    ) -> Result<T, DbError>
    where
        F: FnOnce(&mut pgrx::spi::SpiClient<'_>) -> Result<T, DbError> + UnwindSafe + RefUnwindSafe,
        T: UnwindSafe,
    {
        // Fail before opening a writable SPI transaction.  On a hot standby,
        // pgrx's mutable path asks PostgreSQL for an XID and the resulting
        // recovery ERROR is not reliably exposed with SQLSTATE 25006.  The
        // direct core probe is main-thread-only and gives the HTTP layer one
        // stable, body-free ServiceUnavailable response for every mutation.
        if writable && unsafe { pgrx::pg_sys::RecoveryInProgress() } {
            return Err(DbError {
                message: "the pgs3 endpoint is a read-only standby".to_owned(),
                sqlstate: Some("25006".to_owned()),
                detail: None,
            });
        }
        let role = role.map(str::to_owned);
        self.transaction(move || {
            Spi::connect_mut(|client| {
                let query = request_context_sql(role.as_deref());
                match role {
                    Some(role) => {
                        let args: [DatumWithOid<'_>; 1] = [role.into()];
                        if writable {
                            client.update(query, Some(1), &args).map_err(DbError::spi)?;
                        } else {
                            client.select(query, Some(1), &args).map_err(DbError::spi)?;
                        }
                    }
                    None => {
                        client.select(query, Some(1), &[]).map_err(DbError::spi)?;
                    }
                }
                body(client)
            })
        })
    }

    fn with_role<T, F>(&self, role: &str, writable: bool, body: F) -> Result<T, DbError>
    where
        F: FnOnce(&mut pgrx::spi::SpiClient<'_>) -> Result<T, DbError> + UnwindSafe + RefUnwindSafe,
        T: UnwindSafe,
    {
        self.with_request_context(Some(role), writable, body)
    }
}

fn request_context_sql(role: Option<&str>) -> &'static str {
    if role.is_some() {
        TENANT_REQUEST_CONTEXT_SQL
    } else {
        SERVER_REQUEST_CONTEXT_SQL
    }
}

impl Database for PgDatabase {
    fn lookup_credential(&mut self, access_key: &str) -> Result<Option<Credential>, DbError> {
        let access_key = access_key.to_owned();
        self.with_request_context(None, false, move |client| {
            let args: [DatumWithOid<'_>; 1] = [access_key.into()];
            let table = client
                .select(
                    "SELECT c.secret, c.role_name::text \
                           FROM pgs3.credential AS c \
                           JOIN pg_catalog.pg_roles AS r ON r.rolname = c.role_name \
                          WHERE c.access_key = $1 AND c.enabled \
                            AND NOT r.rolsuper AND NOT r.rolbypassrls \
                            AND pg_catalog.pg_has_role(session_user, c.role_name, 'SET')",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            if table.is_empty() {
                return Ok(None);
            }
            Ok(Some(Credential {
                secret: required(&table, 1)?,
                role: required(&table, 2)?,
            }))
        })
    }

    fn list_buckets(&mut self, role: &str) -> Result<Vec<BucketRecord>, DbError> {
        self.with_role(role, false, |client| {
            let table = client
                .select(
                    "SELECT b.name, b.owner::text, \
                            (extract(epoch FROM b.created_at) * 1000)::bigint \
                       FROM pgs3.list_buckets() AS b",
                    None,
                    &[],
                )
                .map_err(DbError::spi)?;
            let mut rows = Vec::with_capacity(table.len());
            for row in table {
                rows.push(BucketRecord {
                    name: required(&row, 1)?,
                    owner: required(&row, 2)?,
                    created_ms: required(&row, 3)?,
                });
            }
            Ok(rows)
        })
    }

    fn create_bucket(&mut self, role: &str, bucket: &str, region: &str) -> Result<(), DbError> {
        let args: [DatumWithOid<'_>; 2] = [bucket.to_owned().into(), region.to_owned().into()];
        self.with_role(role, true, move |client| {
            client
                .update(
                    "SELECT pgs3.create_bucket($1, pg_catalog.jsonb_build_object('region', $2))",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?;
            Ok(())
        })
    }

    fn delete_bucket(&mut self, role: &str, bucket: &str) -> Result<(), DbError> {
        scalar_void(self, role, true, "SELECT pgs3.delete_bucket($1)", bucket)
    }

    fn head_bucket(&mut self, role: &str, bucket: &str) -> Result<(), DbError> {
        scalar_void(self, role, false, "SELECT pgs3.head_bucket($1)", bucket)
    }

    fn bucket_location(&mut self, role: &str, bucket: &str) -> Result<String, DbError> {
        let args: [DatumWithOid<'_>; 1] = [bucket.to_owned().into()];
        self.with_role(role, false, move |client| {
            let table = client
                .select("SELECT pgs3.get_bucket_location($1)", Some(1), &args)
                .map_err(DbError::spi)?
                .first();
            required(&table, 1)
        })
    }

    fn put_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        body: &[u8],
        content_type: &str,
        meta_json: &str,
        if_none_match: Option<&str>,
        if_match: Option<&str>,
        expected_sha256: Option<&[u8]>,
    ) -> Result<ObjectRecord, DbError> {
        let args: [DatumWithOid<'_>; 8] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            body.to_vec().into(),
            content_type.to_owned().into(),
            meta_json.to_owned().into(),
            if_none_match.map(str::to_owned).into(),
            if_match.map(str::to_owned).into(),
            expected_sha256.map(<[u8]>::to_vec).into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    &format!(
                        "SELECT {} FROM pgs3.put($1,$2,$3,$4,$5::jsonb,$6,$7,$8) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }

    fn head_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: Option<i64>,
    ) -> Result<ObjectRecord, DbError> {
        let args: [DatumWithOid<'_>; 3] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            version_id.into(),
        ];
        self.with_role(role, false, move |client| {
            let table = client
                .select(
                    &format!(
                        "SELECT {} FROM pgs3.head($1, $2, $3) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }

    fn current_delete_marker(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
    ) -> Result<Option<DeleteMarkerRecord>, DbError> {
        let args: [DatumWithOid<'_>; 2] = [bucket.to_owned().into(), key.to_owned().into()];
        self.with_role(role, false, move |client| {
            // list_versions is SECURITY DEFINER but resolves the bucket through
            // the transaction-local tenant actor.  Reusing it keeps this marker
            // probe behind the same bucket boundary as every public read API;
            // direct table access by the server role could disclose another
            // tenant's current marker.
            let table = client
                .select(
                    "SELECT v.version_id \
                       FROM pgs3.list_versions($1,$2,NULL,NULL,NULL,1) AS v \
                      WHERE v.key = $2 COLLATE \"C\" \
                        AND v.is_latest \
                        AND v.delete_marker \
                      LIMIT 1",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            if table.is_empty() {
                Ok(None)
            } else {
                Ok(Some(DeleteMarkerRecord {
                    version_id: required(&table, 1)?,
                }))
            }
        })
    }

    fn get_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: Option<i64>,
    ) -> Result<ObjectData, DbError> {
        let args: [DatumWithOid<'_>; 3] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            version_id.into(),
        ];
        self.with_role(role, false, move |client| {
            let table = client
                .select(
                    &format!(
                        "SELECT {}, d.body FROM pgs3.get($1, $2, $3) AS d",
                        object_columns("(d.info)")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            Ok(ObjectData {
                info: object_record(&table, 0)?,
                body: required(&table, 10)?,
            })
        })
    }

    fn get_range(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: i64,
        start: i64,
        end: i64,
    ) -> Result<Vec<u8>, DbError> {
        let args: [DatumWithOid<'_>; 5] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            start.into(),
            end.into(),
            version_id.into(),
        ];
        self.with_role(role, false, move |client| {
            let table = client
                .select("SELECT pgs3.get_range($1, $2, $3, $4, $5)", Some(1), &args)
                .map_err(DbError::spi)?
                .first();
            required(&table, 1)
        })
    }

    fn delete_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: Option<i64>,
    ) -> Result<DeleteRecord, DbError> {
        let args: [DatumWithOid<'_>; 3] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            version_id.into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    "SELECT d.key, d.version_id, d.delete_marker, d.deleted \
                       FROM pgs3.delete($1, $2, $3) AS d",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            delete_record(&table)
        })
    }

    fn delete_many(
        &mut self,
        role: &str,
        bucket: &str,
        objects: &[DeleteTarget],
    ) -> Result<Vec<Result<DeleteRecord, DbError>>, DbError> {
        let bucket = bucket.to_owned();
        let objects = objects.to_vec();
        self.with_role(role, true, move |client| {
            let keys: Vec<String> = objects.iter().map(|object| object.key.clone()).collect();
            let versions: Vec<Option<i64>> =
                objects.iter().map(|object| object.version_id).collect();
            let args: [DatumWithOid<'_>; 3] = [bucket.into(), keys.into(), versions.into()];
            let table = client
                .update(
                    "SELECT d.key, d.version_id, d.delete_marker, d.deleted \
                       FROM pgs3.delete_many($1, $2, $3) AS d",
                    None,
                    &args,
                )
                .map_err(DbError::spi)?;
            let mut results = Vec::with_capacity(table.len());
            for row in table {
                results.push(Ok(delete_record(&row)?));
            }
            if results.len() != objects.len() {
                return Err(DbError::internal(format!(
                    "delete_many returned {} rows for {} targets",
                    results.len(),
                    objects.len()
                )));
            }
            Ok(results)
        })
    }

    fn copy_object(
        &mut self,
        role: &str,
        source_bucket: &str,
        source_key: &str,
        destination_bucket: &str,
        destination_key: &str,
        source_version_id: Option<i64>,
        content_type: Option<&str>,
        meta_json: Option<&str>,
        if_none_match: Option<&str>,
        if_match: Option<&str>,
        source_if_match: Option<&str>,
    ) -> Result<ObjectRecord, DbError> {
        let args: [DatumWithOid<'_>; 10] = [
            source_bucket.to_owned().into(),
            source_key.to_owned().into(),
            destination_bucket.to_owned().into(),
            destination_key.to_owned().into(),
            source_version_id.into(),
            content_type.map(str::to_owned).into(),
            meta_json.map(str::to_owned).into(),
            if_none_match.map(str::to_owned).into(),
            if_match.map(str::to_owned).into(),
            source_if_match.map(str::to_owned).into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    &format!(
                        "SELECT {} FROM pgs3.copy($1,$2,$3,$4,$5,$6,$7::jsonb,$8,$9,$10) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }

    fn restore_object(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: i64,
        if_match: Option<&str>,
    ) -> Result<ObjectRecord, DbError> {
        let args: [DatumWithOid<'_>; 4] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            version_id.into(),
            if_match.map(str::to_owned).into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    &format!(
                        "SELECT {} FROM pgs3.restore($1,$2,$3,$4) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }

    fn list_objects(
        &mut self,
        role: &str,
        bucket: &str,
        params: &ListParams,
        v2: bool,
    ) -> Result<Vec<ListRecord>, DbError> {
        let probe_bucket = bucket.to_owned();
        let probe_prefix = params.prefix.clone();
        let probe_delimiter = params.delimiter.clone();
        let max_keys = params.max_keys;
        let args: [DatumWithOid<'_>; 6] = [
            bucket.to_owned().into(),
            params.prefix.clone().into(),
            params.delimiter.clone().into(),
            (if v2 {
                params.start_after.clone()
            } else {
                params.marker.clone()
            })
            .into(),
            params.continuation_token.clone().into(),
            params.max_keys.into(),
        ];
        self.with_role(role, false, move |client| {
            let function = if v2 { "list_objects_v2" } else { "list" };
            let query = format!(
                "SELECT l.key, l.common_prefix, l.version_id, l.size, l.etag, \
                        (extract(epoch FROM l.last_modified) * 1000)::bigint, \
                        l.continuation_token \
                   FROM pgs3.{function}($1,$2,$3,$4,$5,$6) AS l"
            );
            let table = client.select(&query, None, &args).map_err(DbError::spi)?;
            let mut rows = Vec::with_capacity(table.len());
            for row in table {
                rows.push(ListRecord {
                    key: optional(&row, 1)?,
                    common_prefix: optional(&row, 2)?,
                    version_id: optional(&row, 3)?,
                    size: optional(&row, 4)?,
                    etag: optional(&row, 5)?,
                    last_modified_ms: optional(&row, 6)?,
                    continuation_token: optional(&row, 7)?,
                });
            }
            if max_keys > 0
                && rows.len() == max_keys as usize
                && let Some(token) = rows.last().and_then(|row| row.continuation_token.clone())
            {
                let probe_args: [DatumWithOid<'_>; 4] = [
                    probe_bucket.into(),
                    probe_prefix.into(),
                    probe_delimiter.into(),
                    token.into(),
                ];
                let probe = client
                    .select(
                        "SELECT 1 FROM pgs3.list($1,$2,$3,NULL,$4,1) LIMIT 1",
                        Some(1),
                        &probe_args,
                    )
                    .map_err(DbError::spi)?;
                if probe.is_empty()
                    && let Some(last) = rows.last_mut()
                {
                    last.continuation_token = None;
                }
            }
            Ok(rows)
        })
    }

    fn list_versions(
        &mut self,
        role: &str,
        bucket: &str,
        params: &VersionListParams,
    ) -> Result<Vec<VersionRecord>, DbError> {
        let probe_bucket = bucket.to_owned();
        let probe_prefix = params.prefix.clone();
        let probe_delimiter = params.delimiter.clone();
        let max_keys = params.max_keys;
        let args: [DatumWithOid<'_>; 6] = [
            bucket.to_owned().into(),
            params.prefix.clone().into(),
            params.delimiter.clone().into(),
            params.key_marker.clone().into(),
            params.version_id_marker.into(),
            params.max_keys.into(),
        ];
        self.with_role(role, false, move |client| {
            let table = client
                .select(
                    "SELECT v.key, v.common_prefix, v.version_id, v.is_latest, \
                            v.delete_marker, v.size, v.etag, \
                            (extract(epoch FROM v.last_modified) * 1000)::bigint, \
                            v.next_key_marker, v.next_version_id_marker \
                       FROM pgs3.list_versions($1,$2,$3,$4,$5,$6) AS v",
                    None,
                    &args,
                )
                .map_err(DbError::spi)?;
            let mut rows = Vec::with_capacity(table.len());
            for row in table {
                rows.push(VersionRecord {
                    key: optional(&row, 1)?,
                    common_prefix: optional(&row, 2)?,
                    version_id: optional(&row, 3)?,
                    is_latest: optional(&row, 4)?,
                    delete_marker: optional(&row, 5)?,
                    size: optional(&row, 6)?,
                    etag: optional(&row, 7)?,
                    last_modified_ms: optional(&row, 8)?,
                    next_key_marker: optional(&row, 9)?,
                    next_version_id_marker: optional(&row, 10)?,
                });
            }
            if max_keys > 0
                && rows.len() == max_keys as usize
                && let Some(key_marker) = rows.last().and_then(|row| row.next_key_marker.clone())
            {
                let version_marker = rows.last().and_then(|row| row.next_version_id_marker);
                let probe_args: [DatumWithOid<'_>; 5] = [
                    probe_bucket.into(),
                    probe_prefix.into(),
                    probe_delimiter.into(),
                    key_marker.into(),
                    version_marker.into(),
                ];
                let probe = client
                    .select(
                        "SELECT 1 FROM pgs3.list_versions($1,$2,$3,$4,$5,1) LIMIT 1",
                        Some(1),
                        &probe_args,
                    )
                    .map_err(DbError::spi)?;
                if probe.is_empty()
                    && let Some(last) = rows.last_mut()
                {
                    last.next_key_marker = None;
                    last.next_version_id_marker = None;
                }
            }
            Ok(rows)
        })
    }

    fn begin_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        content_type: &str,
        meta_json: &str,
        multipart: bool,
        if_none_match: Option<&str>,
        if_match: Option<&str>,
        expected_sha256: Option<&[u8]>,
    ) -> Result<String, DbError> {
        let args: [DatumWithOid<'_>; 8] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            content_type.to_owned().into(),
            meta_json.to_owned().into(),
            multipart.into(),
            if_none_match.map(str::to_owned).into(),
            if_match.map(str::to_owned).into(),
            expected_sha256.map(<[u8]>::to_vec).into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    "SELECT pgs3.begin_upload($1,$2,$3,$4::jsonb,$5,$6,$7,$8)::text",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            required(&table, 1)
        })
    }

    fn renew_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        require_multipart: bool,
    ) -> Result<(), DbError> {
        let args: [DatumWithOid<'_>; 4] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            upload_id.to_owned().into(),
            require_multipart.into(),
        ];
        self.with_role(role, true, move |client| {
            client
                .update(
                    "SELECT pgs3.renew_upload($1,$2,$3::uuid,$4)",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?;
            Ok(())
        })
    }

    fn put_chunk(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        seq: i32,
        data: &[u8],
        part_number: i32,
    ) -> Result<(), DbError> {
        let bucket = bucket.to_owned();
        let key = key.to_owned();
        let upload_id = upload_id.to_owned();
        self.with_role(role, true, move |client| {
            // Build bytea only after SPI opened the transaction.  &[u8]
            // IntoDatum performs the one required copy into PostgreSQL's
            // current memory context; an intermediate Rust Vec is redundant.
            let args: [DatumWithOid<'_>; 6] = [
                bucket.into(),
                key.into(),
                upload_id.into(),
                seq.into(),
                data.into(),
                part_number.into(),
            ];
            client
                .update(
                    "SELECT pgs3.put_chunk($1,$2,$3::uuid,$4,$5,$6,NULL)",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?;
            Ok(())
        })
    }

    fn put_chunk_sealed(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        seq: i32,
        data: &[u8],
        server_sha256: &[u8],
    ) -> Result<ChunkRecord, DbError> {
        let role = role.to_owned();
        let bucket = bucket.to_owned();
        let key = key.to_owned();
        let upload_id = upload_id.to_owned();
        self.with_request_context(None, true, move |client| {
            let args: [DatumWithOid<'_>; 7] = [
                role.into(),
                bucket.into(),
                key.into(),
                upload_id.into(),
                seq.into(),
                data.into(),
                server_sha256.into(),
            ];
            let row = client
                .update(
                    "SELECT c.blob_id, c.size FROM \
                     pgs3._worker_put_chunk($1::name,$2,$3,$4::uuid,$5,$6,$7) AS c",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            Ok(ChunkRecord {
                blob_id: required(&row, 1)?,
                size: required(&row, 2)?,
            })
        })
    }

    fn complete_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        expected_sha256: Option<&[u8]>,
    ) -> Result<ObjectRecord, DbError> {
        let args: [DatumWithOid<'_>; 4] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            upload_id.to_owned().into(),
            expected_sha256.map(<[u8]>::to_vec).into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    &format!(
                        "SELECT {} FROM pgs3.complete_upload($1,$2,$3::uuid,$4) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }

    fn complete_upload_sealed(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        expected_sha256: Option<&[u8]>,
        server_sha256: &[u8],
        server_md5: &str,
        server_size: i64,
        chunk_blob_ids: &[Vec<u8>],
        chunk_sizes: &[i64],
    ) -> Result<ObjectRecord, DbError> {
        let role = role.to_owned();
        let bucket = bucket.to_owned();
        let key = key.to_owned();
        let upload_id = upload_id.to_owned();
        let expected_sha256 = expected_sha256.map(<[u8]>::to_vec);
        let server_sha256 = server_sha256.to_vec();
        let server_md5 = server_md5.to_owned();
        let chunk_blob_ids = chunk_blob_ids.to_vec();
        let chunk_sizes = chunk_sizes.to_vec();
        self.with_request_context(None, true, move |client| {
            // PostgreSQL arrays must be allocated inside the active SPI
            // transaction; see complete_multipart for the same pgrx boundary.
            let args: [DatumWithOid<'_>; 10] = [
                role.into(),
                bucket.into(),
                key.into(),
                upload_id.into(),
                expected_sha256.into(),
                server_sha256.into(),
                server_md5.into(),
                server_size.into(),
                chunk_blob_ids.into(),
                chunk_sizes.into(),
            ];
            let table = client
                .update(
                    &format!(
                        "SELECT {} FROM pgs3._worker_complete_upload(\
                            $1::name,$2,$3,$4::uuid,$5,$6,$7,$8,$9::bytea[],$10::bigint[]\
                         ) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }

    fn finish_upload_sealed(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        expected_sha256: Option<&[u8]>,
        server_sha256: &[u8],
        server_md5: &str,
        server_size: i64,
        chunk_blob_ids: &[Vec<u8>],
        chunk_sizes: &[i64],
        final_seq: i32,
        final_data: &[u8],
        final_sha256: &[u8],
    ) -> Result<ObjectRecord, DbError> {
        let role = role.to_owned();
        let bucket = bucket.to_owned();
        let key = key.to_owned();
        let upload_id = upload_id.to_owned();
        let expected_sha256 = expected_sha256.map(<[u8]>::to_vec);
        let server_sha256 = server_sha256.to_vec();
        let server_md5 = server_md5.to_owned();
        let mut chunk_blob_ids = chunk_blob_ids.to_vec();
        let mut chunk_sizes = chunk_sizes.to_vec();
        self.with_request_context(None, true, move |client| {
            // Persist the final buffered chunk and publish while retaining the
            // same upload-row lock and transaction.  This removes one durable
            // boundary without weakening independently committed earlier
            // chunks or the exact final manifest comparison.
            let chunk_args: [DatumWithOid<'_>; 7] = [
                role.as_str().into(),
                bucket.as_str().into(),
                key.as_str().into(),
                upload_id.as_str().into(),
                final_seq.into(),
                final_data.into(),
                final_sha256.into(),
            ];
            let row = client
                .update(
                    "SELECT c.blob_id, c.size FROM \
                     pgs3._worker_put_chunk($1::name,$2,$3,$4::uuid,$5,$6,$7) AS c",
                    Some(1),
                    &chunk_args,
                )
                .map_err(DbError::spi)?
                .first();
            chunk_blob_ids.push(required(&row, 1)?);
            chunk_sizes.push(required(&row, 2)?);

            let complete_args: [DatumWithOid<'_>; 10] = [
                role.into(),
                bucket.into(),
                key.into(),
                upload_id.into(),
                expected_sha256.into(),
                server_sha256.into(),
                server_md5.into(),
                server_size.into(),
                chunk_blob_ids.into(),
                chunk_sizes.into(),
            ];
            let table = client
                .update(
                    &format!(
                        "SELECT {} FROM pgs3._worker_complete_upload(\
                            $1::name,$2,$3,$4::uuid,$5,$6,$7,$8,$9::bytea[],$10::bigint[]\
                         ) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &complete_args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }

    fn abort_upload(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        multipart: bool,
    ) -> Result<(), DbError> {
        let args: [DatumWithOid<'_>; 4] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            upload_id.to_owned().into(),
            multipart.into(),
        ];
        self.with_role(role, true, move |client| {
            client
                .update(
                    "SELECT pgs3.abort_upload($1,$2,$3::uuid,$4)",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?;
            Ok(())
        })
    }

    fn begin_part(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        part_number: i32,
    ) -> Result<(), DbError> {
        upload_action(
            self,
            role,
            "begin_part",
            bucket,
            key,
            upload_id,
            part_number,
        )
    }

    fn abort_part(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        part_number: i32,
    ) -> Result<(), DbError> {
        upload_action(
            self,
            role,
            "abort_part",
            bucket,
            key,
            upload_id,
            part_number,
        )
    }

    fn complete_part(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        part_number: i32,
        expected_sha256: Option<&[u8]>,
    ) -> Result<PartRecord, DbError> {
        let args: [DatumWithOid<'_>; 5] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            upload_id.to_owned().into(),
            part_number.into(),
            expected_sha256.map(<[u8]>::to_vec).into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    "SELECT p.part_number, p.size, p.etag, p.sha256, \
                            (extract(epoch FROM p.completed_at) * 1000)::bigint \
                       FROM pgs3.complete_part($1,$2,$3::uuid,$4,$5) AS p",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            part_record(&table)
        })
    }

    fn list_parts(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
    ) -> Result<Vec<PartRecord>, DbError> {
        let args: [DatumWithOid<'_>; 3] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            upload_id.to_owned().into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    "SELECT p.part_number, p.size, p.etag, p.sha256, \
                            (extract(epoch FROM p.completed_at) * 1000)::bigint \
                       FROM pgs3.list_parts($1,$2,$3::uuid) AS p",
                    None,
                    &args,
                )
                .map_err(DbError::spi)?;
            let mut rows = Vec::with_capacity(table.len());
            for row in table {
                rows.push(part_record(&row)?);
            }
            Ok(rows)
        })
    }

    fn multipart_checksum_algorithm(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
    ) -> Result<Option<String>, DbError> {
        let args: [DatumWithOid<'_>; 3] = [
            bucket.to_owned().into(),
            key.to_owned().into(),
            upload_id.to_owned().into(),
        ];
        self.with_role(role, true, move |client| {
            let table = client
                .update(
                    "SELECT pgs3.multipart_checksum_algorithm($1,$2,$3::uuid)",
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            optional(&table, 1)
        })
    }

    fn complete_multipart(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        upload_id: &str,
        parts: &[i32],
        etags: &[String],
        expected_sha256: Option<&[u8]>,
        part_sha256s: Option<&[Vec<u8>]>,
        composite_sha256: Option<&str>,
    ) -> Result<ObjectRecord, DbError> {
        // Vec<T>::into_datum() builds a PostgreSQL ArrayType in the current
        // memory context.  Construct these arrays only after with_role has
        // started the transaction and opened SPI; creating them in the idle
        // worker context can leave the array allocated across transaction
        // context changes and crash after a large multipart completion.
        let bucket = bucket.to_owned();
        let key = key.to_owned();
        let upload_id = upload_id.to_owned();
        let parts = parts.to_vec();
        let etags = etags.to_vec();
        let expected_sha256 = expected_sha256.map(<[u8]>::to_vec);
        let part_sha256s = part_sha256s.map(<[Vec<u8>]>::to_vec);
        let composite_sha256 = composite_sha256.map(str::to_owned);
        self.with_role(role, true, move |client| {
            let args: [DatumWithOid<'_>; 8] = [
                bucket.into(),
                key.into(),
                upload_id.into(),
                parts.into(),
                etags.into(),
                expected_sha256.into(),
                part_sha256s.into(),
                composite_sha256.into(),
            ];
            let table = client
                .update(
                    &format!(
                        "SELECT {} FROM pgs3.complete_multipart_upload(\
                            $1,$2,$3::uuid,$4,$5,$6,$7::bytea[],$8\
                         ) AS i",
                        object_columns("i")
                    ),
                    Some(1),
                    &args,
                )
                .map_err(DbError::spi)?
                .first();
            object_record(&table, 0)
        })
    }
}

fn scalar_void(
    database: &PgDatabase,
    role: &str,
    writable: bool,
    query: &'static str,
    value: &str,
) -> Result<(), DbError> {
    let args: [DatumWithOid<'_>; 1] = [value.to_owned().into()];
    database.with_role(role, writable, move |client| {
        if writable {
            client.update(query, Some(1), &args).map_err(DbError::spi)?;
        } else {
            client.select(query, Some(1), &args).map_err(DbError::spi)?;
        }
        Ok(())
    })
}

fn upload_action(
    database: &PgDatabase,
    role: &str,
    function: &'static str,
    bucket: &str,
    key: &str,
    upload_id: &str,
    part_number: i32,
) -> Result<(), DbError> {
    let args: [DatumWithOid<'_>; 4] = [
        bucket.to_owned().into(),
        key.to_owned().into(),
        upload_id.to_owned().into(),
        part_number.into(),
    ];
    database.with_role(role, true, move |client| {
        let query = format!("SELECT pgs3.{function}($1,$2,$3::uuid,$4)");
        client
            .update(&query, Some(1), &args)
            .map_err(DbError::spi)?;
        Ok(())
    })
}

fn object_columns(prefix: &str) -> String {
    format!(
        "{prefix}.bucket, {prefix}.key, {prefix}.version_id, {prefix}.size, \
         {prefix}.etag, {prefix}.sha256, {prefix}.content_type, {prefix}.meta::text, \
         (extract(epoch FROM {prefix}.created_at) * 1000)::bigint"
    )
}

fn object_record<R: SpiRow>(row: &R, offset: usize) -> Result<ObjectRecord, DbError> {
    Ok(ObjectRecord {
        bucket: required(row, offset + 1)?,
        key: required(row, offset + 2)?,
        version_id: required(row, offset + 3)?,
        size: required(row, offset + 4)?,
        etag: required(row, offset + 5)?,
        sha256: required(row, offset + 6)?,
        content_type: optional(row, offset + 7)?,
        meta_json: required(row, offset + 8)?,
        created_ms: required(row, offset + 9)?,
    })
}

fn delete_record<R: SpiRow>(row: &R) -> Result<DeleteRecord, DbError> {
    Ok(DeleteRecord {
        key: required(row, 1)?,
        version_id: required(row, 2)?,
        delete_marker: required(row, 3)?,
        deleted: required(row, 4)?,
    })
}

fn part_record<R: SpiRow>(row: &R) -> Result<PartRecord, DbError> {
    Ok(PartRecord {
        part_number: required(row, 1)?,
        size: required(row, 2)?,
        etag: required(row, 3)?,
        sha256: required(row, 4)?,
        completed_ms: required(row, 5)?,
    })
}

trait SpiRow {
    fn value<T: FromDatum + IntoDatum>(&self, ordinal: usize) -> pgrx::spi::Result<Option<T>>;
}

impl SpiRow for pgrx::spi::SpiTupleTable<'_> {
    fn value<T: FromDatum + IntoDatum>(&self, ordinal: usize) -> pgrx::spi::Result<Option<T>> {
        self.get(ordinal)
    }
}

impl SpiRow for pgrx::spi::SpiHeapTupleData<'_> {
    fn value<T: FromDatum + IntoDatum>(&self, ordinal: usize) -> pgrx::spi::Result<Option<T>> {
        self.get(ordinal)
    }
}

fn required<T: FromDatum + IntoDatum, R: SpiRow>(row: &R, ordinal: usize) -> Result<T, DbError> {
    row.value(ordinal).map_err(DbError::spi)?.ok_or_else(|| {
        DbError::internal(format!(
            "semantic SQL unexpectedly returned NULL at column {ordinal}"
        ))
    })
}

fn optional<T: FromDatum + IntoDatum, R: SpiRow>(
    row: &R,
    ordinal: usize,
) -> Result<Option<T>, DbError> {
    row.value(ordinal).map_err(DbError::spi)
}

fn caught_error(cause: &CaughtError) -> (String, Option<String>, Option<String>) {
    let report = match cause {
        CaughtError::PostgresError(report) | CaughtError::ErrorReport(report) => report,
        CaughtError::RustPanic { ereport, .. } => ereport,
    };
    (
        report.message().to_owned(),
        Some(unpack_sqlstate(report.sql_error_code() as i32)),
        report.detail().map(str::to_owned),
    )
}

// PostgreSQL packs each SQLSTATE character into six bits, least-significant
// character first (MAKE_SQLSTATE/PGSIXBIT). Decode it locally so ordinary
// Rust unit-test binaries do not acquire a link-time dependency on the server's
// `unpack_sql_state` symbol.
fn unpack_sqlstate(mut code: i32) -> String {
    let mut state = String::with_capacity(5);
    for _ in 0..5 {
        state.push(char::from(((code & 0x3f) as u8) + b'0'));
        code >>= 6;
    }
    state
}

#[cfg(test)]
mod tests {
    use super::{SERVER_REQUEST_CONTEXT_SQL, TENANT_REQUEST_CONTEXT_SQL, request_context_sql};

    #[test]
    fn server_auth_context_sets_only_a_transaction_local_timeout() {
        assert_eq!(request_context_sql(None), SERVER_REQUEST_CONTEXT_SQL);
        assert!(SERVER_REQUEST_CONTEXT_SQL.contains("'statement_timeout'"));
        assert!(SERVER_REQUEST_CONTEXT_SQL.contains("'lock_timeout'"));
        assert!(SERVER_REQUEST_CONTEXT_SQL.contains("'pgs3.statement_timeout_ms'"));
        assert!(SERVER_REQUEST_CONTEXT_SQL.contains("true"));
        assert!(SERVER_REQUEST_CONTEXT_SQL.trim_end().ends_with(')'));
        assert!(!SERVER_REQUEST_CONTEXT_SQL.contains("'role'"));
    }

    #[test]
    fn tenant_context_keeps_timeout_and_transaction_local_role() {
        assert_eq!(
            request_context_sql(Some("tenant")),
            TENANT_REQUEST_CONTEXT_SQL
        );
        assert!(TENANT_REQUEST_CONTEXT_SQL.contains("'statement_timeout'"));
        assert!(TENANT_REQUEST_CONTEXT_SQL.contains("'lock_timeout'"));
        assert!(TENANT_REQUEST_CONTEXT_SQL.contains("'pgs3.statement_timeout_ms'"));
        assert!(TENANT_REQUEST_CONTEXT_SQL.contains("'role'"));
    }
}
