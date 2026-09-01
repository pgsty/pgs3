use std::collections::BTreeMap;
use std::time::{Duration, Instant, SystemTime};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use md5::Md5;
use quick_xml::Reader;
use quick_xml::events::Event;
use sha1::Sha1;
use sha2::{Digest, Sha256};

use crate::protocol::chunked::{
    AwsChunkedDecoder, AwsChunkedMode, CRC32C, CRC64NVME, ChunkedError, ChunkedLimits,
    DecodedTrailer,
};
use crate::protocol::headers::{
    ByteRangeSpec, ConditionalHeaders, EntityTag, IfRange, PreconditionResult,
};
use crate::protocol::http::{HeaderMap, RequestHead};
use crate::protocol::sigv4::{
    PayloadMode, SigV4Error, SigV4Request, VerificationConfig, VerifiedSignature, constant_time_eq,
    hex_lower, parse_header_authorization, parse_presigned_authorization, verify_header,
    verify_presigned,
};
use crate::protocol::xml::{
    BucketDescription, CompleteMultipartUpload, DeleteObjectError, DeletedObject, XmlLimits,
    parse_complete_multipart, parse_delete_objects, serialize_bucket_location,
    serialize_complete_multipart, serialize_copy_result, serialize_delete_result,
    serialize_initiate_multipart, serialize_list_buckets, serialize_versioning_enabled,
};

use super::db::{
    Database, DbError, DeleteMarkerRecord, DeleteTarget, ObjectRecord, PartRecord, PgDatabase,
};
use super::route::{ListPartsParams, Operation, classify};
use super::types::{S3Error, ServiceResponse, request_id};
use super::xml;

// These JSON keys cannot collide with user metadata: ':' is not valid in an
// HTTP field name, so no x-amz-meta-* request header can produce them.
const STORED_CACHE_CONTROL: &str = "@pgs3:cache-control";
const STORED_EXPIRES: &str = "@pgs3:expires";
const STORED_CONTENT_ENCODING: &str = "@pgs3:content-encoding";
const STORED_CHECKSUM_CRC32: &str = "@pgs3:checksum-crc32";
const STORED_CHECKSUM_CRC32C: &str = "@pgs3:checksum-crc32c";
const STORED_CHECKSUM_SHA1: &str = "@pgs3:checksum-sha1";
const STORED_CHECKSUM_SHA256: &str = "@pgs3:checksum-sha256";
const STORED_CHECKSUM_CRC64NVME: &str = "@pgs3:checksum-crc64nvme";
const STORED_CHECKSUM_ALGORITHM: &str = "@pgs3:checksum-algorithm";
const STORED_CHECKSUM_TYPE: &str = "@pgs3:checksum-type";
const CHECKSUM_TYPE_COMPOSITE: &str = "COMPOSITE";
const MAX_DIRECT_PUT_BYTES: usize = 64 * 1024;
const MIN_STAGING_CHUNK_BYTES: usize = 64 * 1024;
const MAX_STAGING_CHUNK_BYTES: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug)]
pub(crate) struct ServiceConfig {
    pub expected_region: Option<String>,
    pub max_clock_skew: Duration,
    pub max_object_bytes: u64,
    pub max_control_body_bytes: usize,
    pub staging_chunk_bytes: usize,
    pub direct_put_bytes: usize,
    pub xml_limits: XmlLimits,
}

impl Default for ServiceConfig {
    fn default() -> Self {
        Self {
            expected_region: None,
            max_clock_skew: Duration::from_secs(15 * 60),
            max_object_bytes: 5 * 1024 * 1024 * 1024,
            max_control_body_bytes: 1024 * 1024,
            staging_chunk_bytes: 4 * 1024 * 1024,
            direct_put_bytes: 64 * 1024,
            xml_limits: XmlLimits::default(),
        }
    }
}

const UPLOAD_LEASE_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Clone, Copy, Debug)]
struct UploadLeaseHeartbeat {
    next: Instant,
}

impl UploadLeaseHeartbeat {
    fn new(now: Instant) -> Self {
        Self {
            next: now + UPLOAD_LEASE_HEARTBEAT_INTERVAL,
        }
    }

    fn touched(&mut self, now: Instant) {
        self.next = now + UPLOAD_LEASE_HEARTBEAT_INTERVAL;
    }

    fn renew_if_due<E>(
        &mut self,
        now: Instant,
        renew: impl FnOnce() -> Result<(), E>,
    ) -> Result<bool, E> {
        if now < self.next {
            return Ok(false);
        }
        renew()?;
        self.touched(now);
        Ok(true)
    }
}

pub(crate) enum HeadOutcome {
    Immediate(ServiceResponse),
    ReceiveBody(Box<BodySession>),
}

pub(crate) struct BodySession {
    request_id: String,
    resource: String,
    role: String,
    operation: Operation,
    headers: HeaderMap,
    payload_mode: PayloadMode,
    decoder: Option<AwsChunkedDecoder>,
    sink: BodySink,
    digests: BodyDigests,
    expected_checksums: ExpectedChecksums,
    expected_wire_bytes: Option<u64>,
    wire_bytes: u64,
    decoded_bytes: u64,
    max_decoded_bytes: u64,
    lease_heartbeat: Option<UploadLeaseHeartbeat>,
    active: bool,
}

enum BodySink {
    DirectPut {
        bucket: String,
        key: String,
        content_type: String,
        meta_json: String,
        if_none_match: Option<String>,
        if_match: Option<String>,
        expected_sha256: Option<Vec<u8>>,
        max_body_bytes: usize,
        body: Vec<u8>,
    },
    Staged {
        bucket: String,
        key: String,
        upload_id: String,
        part_number: i32,
        sequence: i32,
        staging_chunk_bytes: usize,
        buffer: Vec<u8>,
        chunk_blob_ids: Vec<Vec<u8>>,
        chunk_sizes: Vec<i64>,
    },
    Buffered(Vec<u8>),
}

struct BodyDigests {
    sha256: Sha256,
    md5: Md5,
    sha1: Option<Sha1>,
    crc32: Option<crc32fast::Hasher>,
    crc32c: Option<crc::Digest<'static, u32>>,
    crc64nvme: Option<crc::Digest<'static, u64>>,
}

impl Default for BodyDigests {
    fn default() -> Self {
        Self {
            sha256: Sha256::new(),
            md5: Md5::new(),
            sha1: None,
            crc32: None,
            crc32c: None,
            crc64nvme: None,
        }
    }
}

impl BodyDigests {
    fn for_expected(expected: &ExpectedChecksums) -> Self {
        Self {
            sha1: expected
                .requires_digest(ChecksumAlgorithm::Sha1)
                .then(Sha1::new),
            crc32: expected
                .requires_digest(ChecksumAlgorithm::Crc32)
                .then(crc32fast::Hasher::new),
            crc32c: expected
                .requires_digest(ChecksumAlgorithm::Crc32c)
                .then(|| CRC32C.digest()),
            crc64nvme: expected
                .requires_digest(ChecksumAlgorithm::Crc64Nvme)
                .then(|| CRC64NVME.digest()),
            ..Self::default()
        }
    }

    fn update(&mut self, bytes: &[u8]) {
        self.sha256.update(bytes);
        self.md5.update(bytes);
        if let Some(sha1) = &mut self.sha1 {
            sha1.update(bytes);
        }
        if let Some(crc32) = &mut self.crc32 {
            crc32.update(bytes);
        }
        if let Some(crc32c) = &mut self.crc32c {
            crc32c.update(bytes);
        }
        if let Some(crc64nvme) = &mut self.crc64nvme {
            crc64nvme.update(bytes);
        }
    }

    fn values(&self) -> DigestValues {
        DigestValues {
            sha256: self.sha256.clone().finalize().into(),
            md5: self.md5.clone().finalize().into(),
            sha1: self
                .sha1
                .as_ref()
                .map(|digest| digest.clone().finalize().into()),
            crc32: self
                .crc32
                .as_ref()
                .map(|digest| digest.clone().finalize().to_be_bytes()),
            crc32c: self
                .crc32c
                .as_ref()
                .map(|digest| digest.clone().finalize().to_be_bytes()),
            crc64nvme: self
                .crc64nvme
                .as_ref()
                .map(|digest| digest.clone().finalize().to_be_bytes()),
        }
    }
}

struct DigestValues {
    sha256: [u8; 32],
    md5: [u8; 16],
    sha1: Option<[u8; 20]>,
    crc32: Option<[u8; 4]>,
    crc32c: Option<[u8; 4]>,
    crc64nvme: Option<[u8; 8]>,
}

#[derive(Clone, Debug, Default)]
struct ExpectedChecksums {
    content_md5: Option<Vec<u8>>,
    sha256: Option<Vec<u8>>,
    sha1: Option<Vec<u8>>,
    crc32: Option<Vec<u8>>,
    crc32c: Option<Vec<u8>>,
    crc64nvme: Option<Vec<u8>>,
    declared_trailer_algorithms: Vec<ChecksumAlgorithm>,
}

pub(super) fn map_database_error(
    sqlstate: Option<&str>,
    detail: Option<&str>,
    _diagnostic_message: &str,
) -> S3Error {
    let semantic_code = detail
        .into_iter()
        .flat_map(str::split_ascii_whitespace)
        .find_map(|field| field.strip_prefix("pgs3.error="));
    if let Some(error) = semantic_code.and_then(semantic_database_error) {
        return error;
    }
    match sqlstate {
        Some("42501") => S3Error::access_denied(),
        Some("25006") => S3Error::new(
            503,
            "ServiceUnavailable",
            "This endpoint is a read-only standby and cannot accept writes",
        ),
        Some("57014") => S3Error::new(
            503,
            "SlowDown",
            "The request exceeded the statement time limit",
        ),
        Some("0A000") => S3Error::new(
            501,
            "NotImplemented",
            "The requested operation is not available",
        ),
        Some("P3B01") => S3Error::new(404, "NoSuchBucket", "The specified bucket does not exist"),
        Some("P3U01") => S3Error::new(404, "NoSuchUpload", "The specified upload does not exist"),
        Some("P3K01") => S3Error::new(404, "NoSuchKey", "The specified key does not exist"),
        Some("P3E01") => S3Error::new(
            409,
            "BucketAlreadyExists",
            "The requested bucket name is unavailable",
        ),
        Some("P3F01") => S3Error::new(409, "BucketNotEmpty", "The bucket is not empty"),
        Some("P3C01") => S3Error::new(
            412,
            "PreconditionFailed",
            "At least one precondition failed",
        ),
        Some("P3N01") => S3Error::new(304, "NotModified", "Not Modified"),
        Some("P3H01") => S3Error::new(400, "BadDigest", "The supplied checksum did not match"),
        Some("P3P01") => S3Error::new(
            400,
            "InvalidPart",
            "One or more specified parts could not be found",
        ),
        Some("P3R01") => S3Error::new(
            416,
            "InvalidRange",
            "The requested range is not satisfiable",
        ),
        Some("P3S01") => S3Error::new(400, "EntityTooLarge", "The request entity is too large"),
        Some(state) if state.starts_with("22") => {
            S3Error::new(400, "InvalidArgument", "An argument was invalid")
        }
        _ => S3Error::internal(),
    }
}

fn semantic_database_error(code: &str) -> Option<S3Error> {
    Some(match code {
        "NoSuchBucket" => S3Error::new(404, "NoSuchBucket", "The specified bucket does not exist"),
        "NoSuchUpload" => S3Error::new(404, "NoSuchUpload", "The specified upload does not exist"),
        "NoSuchKey" => S3Error::new(404, "NoSuchKey", "The specified key does not exist"),
        "NoSuchVersion" => {
            S3Error::new(404, "NoSuchVersion", "The specified version does not exist")
        }
        "BucketAlreadyExists" => S3Error::new(
            409,
            "BucketAlreadyExists",
            "The requested bucket name is unavailable",
        ),
        "InvalidBucketName" => S3Error::new(
            400,
            "InvalidBucketName",
            "The specified bucket name is not valid",
        ),
        "BucketNotEmpty" => S3Error::new(409, "BucketNotEmpty", "The bucket is not empty"),
        "PreconditionFailed" => S3Error::new(
            412,
            "PreconditionFailed",
            "At least one precondition failed",
        ),
        "NotModified" => S3Error::new(304, "NotModified", "Not Modified"),
        "BadDigest" => S3Error::new(400, "BadDigest", "The supplied checksum did not match"),
        "InvalidPartOrder" => S3Error::new(
            400,
            "InvalidPartOrder",
            "The list of parts was not in ascending order",
        ),
        "EntityTooSmall" => S3Error::new(400, "EntityTooSmall", "A multipart part was too small"),
        "InvalidPart" => S3Error::new(
            400,
            "InvalidPart",
            "One or more specified parts could not be found",
        ),
        "InvalidRange" => S3Error::new(
            416,
            "InvalidRange",
            "The requested range is not satisfiable",
        ),
        "EntityTooLarge" => S3Error::new(400, "EntityTooLarge", "The request entity is too large"),
        "CredentialError" => S3Error::access_denied(),
        _ => return None,
    })
}

pub(crate) struct PgS3Service<D: Database = PgDatabase> {
    database: D,
    config: ServiceConfig,
}

impl PgS3Service<PgDatabase> {
    pub(crate) fn for_worker() -> Self {
        let mut config = ServiceConfig::default();
        config.direct_put_bytes = crate::config::inline_threshold_bytes();
        config.staging_chunk_bytes = crate::config::chunk_size_bytes();
        Self::new(PgDatabase::new(), config)
    }
}

impl<D: Database> PgS3Service<D> {
    pub(crate) fn new(database: D, mut config: ServiceConfig) -> Self {
        config.staging_chunk_bytes = config
            .staging_chunk_bytes
            .clamp(MIN_STAGING_CHUNK_BYTES, MAX_STAGING_CHUNK_BYTES);
        config.max_control_body_bytes = config.max_control_body_bytes.max(1);
        config.direct_put_bytes = config
            .direct_put_bytes
            .min(config.max_control_body_bytes)
            .min(MAX_DIRECT_PUT_BYTES)
            .min(config.max_object_bytes.try_into().unwrap_or(usize::MAX));
        Self { database, config }
    }

    /// Authenticate and classify one request head. The socket layer must feed
    /// HTTP-framing-decoded entity bytes to the returned session. In
    /// particular, HTTP Transfer-Encoding chunk framing is removed by the
    /// worker, while S3 Content-Encoding: aws-chunked remains for this module.
    pub(crate) fn handle_head(&mut self, request: RequestHead) -> HeadOutcome {
        let id = request_id();
        let resource = request.target.raw_path.clone();
        let head_only = request.method == "HEAD";
        let result = self.authorize(&request).and_then(|(role, verified)| {
            let operation = classify(&request)?;
            self.prepare(
                request,
                operation,
                role,
                verified,
                id.clone(),
                resource.clone(),
            )
        });
        match result {
            Ok(outcome) => outcome,
            Err(error) => {
                HeadOutcome::Immediate(error.response(&resource, &id).finalize(&id, head_only))
            }
        }
    }

    pub(crate) fn push_body(
        &mut self,
        session: &mut BodySession,
        bytes: &[u8],
    ) -> Result<(), ServiceResponse> {
        if !session.active {
            return Err(self.session_error(
                session,
                S3Error::invalid_request("request body session is no longer active"),
            ));
        }
        let byte_count = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
        session.wire_bytes = match session.wire_bytes.checked_add(byte_count) {
            Some(total) => total,
            None => {
                return Err(self.fail_session(
                    session,
                    S3Error::new(400, "EntityTooLarge", "Request entity is too large"),
                ));
            }
        };
        if session
            .expected_wire_bytes
            .is_some_and(|expected| session.wire_bytes > expected)
        {
            return Err(self.fail_session(
                session,
                S3Error::new(
                    400,
                    "IncompleteBody",
                    "More bytes were received than Content-Length",
                ),
            ));
        }
        if let Some(decoder) = &mut session.decoder {
            let mut decoded = Vec::new();
            if let Err(error) = decoder.push(bytes, &mut decoded) {
                return Err(self.fail_session(session, chunked_error(error)));
            }
            if let Err(error) = self.accept_decoded(session, &decoded) {
                return Err(self.fail_session(session, error));
            }
        } else if let Err(error) = self.accept_decoded(session, bytes) {
            return Err(self.fail_session(session, error));
        }
        if let Err(error) = self.renew_upload_lease_if_due(session, Instant::now()) {
            return Err(self.fail_session(session, error.to_s3()));
        }
        Ok(())
    }

    pub(crate) fn finish_body(&mut self, session: &mut BodySession) -> ServiceResponse {
        if !session.active {
            return self.session_error(
                session,
                S3Error::invalid_request("request body session is no longer active"),
            );
        }
        if session
            .expected_wire_bytes
            .is_some_and(|expected| session.wire_bytes != expected)
        {
            return self.fail_session(
                session,
                S3Error::new(
                    400,
                    "IncompleteBody",
                    "Content-Length did not match the received body",
                ),
            );
        }
        if let Some(decoder) = &mut session.decoder {
            if let Err(error) = decoder.finish() {
                return self.fail_session(session, chunked_error(error));
            }
            let verified_trailers = decoder.trailers().to_vec();
            if let Err(error) =
                apply_verified_trailers(&mut session.expected_checksums, &verified_trailers)
            {
                return self.fail_session(session, error);
            }
        }
        let actual_digests = session.digests.values();
        if let Err(error) = verify_digest_values(
            &session.payload_mode,
            &actual_digests,
            &session.expected_checksums,
        ) {
            return self.fail_session(session, error);
        }
        let server_size = match i64::try_from(session.decoded_bytes) {
            Ok(size) => size,
            Err(_) => {
                return self.fail_session(
                    session,
                    S3Error::new(400, "EntityTooLarge", "Decoded body is too large"),
                );
            }
        };
        let server_md5 = hex_lower(&actual_digests.md5);

        let response = match &mut session.sink {
            BodySink::DirectPut {
                bucket,
                key,
                content_type,
                meta_json,
                if_none_match,
                if_match,
                expected_sha256,
                max_body_bytes: _,
                body,
            } => self
                .database
                .put_object(
                    &session.role,
                    bucket,
                    key,
                    body,
                    content_type,
                    meta_json,
                    if_none_match.as_deref(),
                    if_match.as_deref(),
                    expected_sha256.as_deref(),
                )
                .map(|info| put_response(&info))
                .map_err(|error| error.to_s3()),
            BodySink::Staged {
                bucket,
                key,
                upload_id,
                part_number,
                sequence,
                buffer,
                chunk_blob_ids,
                chunk_sizes,
                ..
            } => {
                if *part_number == 0 {
                    let result = if !buffer.is_empty() || *sequence == 0 {
                        let data = std::mem::take(buffer);
                        let chunk_sha256 = if *sequence == 0
                            && u64::try_from(data.len()).ok() == Some(session.decoded_bytes)
                        {
                            actual_digests.sha256.to_vec()
                        } else {
                            Sha256::digest(&data).to_vec()
                        };
                        self.database.finish_upload_sealed(
                            &session.role,
                            bucket,
                            key,
                            upload_id,
                            session.expected_checksums.sha256.as_deref(),
                            &actual_digests.sha256,
                            &server_md5,
                            server_size,
                            chunk_blob_ids,
                            chunk_sizes,
                            *sequence,
                            &data,
                            &chunk_sha256,
                        )
                    } else {
                        self.database.complete_upload_sealed(
                            &session.role,
                            bucket,
                            key,
                            upload_id,
                            session.expected_checksums.sha256.as_deref(),
                            &actual_digests.sha256,
                            &server_md5,
                            server_size,
                            chunk_blob_ids,
                            chunk_sizes,
                        )
                    };
                    result
                        .map(|info| put_response(&info))
                        .map_err(|error| error.to_s3())
                } else {
                    if !buffer.is_empty() || *sequence == 0 {
                        let data = std::mem::take(buffer);
                        if let Err(error) = self.database.put_chunk(
                            &session.role,
                            bucket,
                            key,
                            upload_id,
                            *sequence,
                            &data,
                            *part_number,
                        ) {
                            return self.fail_session(session, error.to_s3());
                        }
                        *sequence += 1;
                    }
                    self.database
                        .complete_part(
                            &session.role,
                            bucket,
                            key,
                            upload_id,
                            *part_number,
                            session.expected_checksums.sha256.as_deref(),
                        )
                        .map(|part| {
                            ServiceResponse::empty(200)
                                .header("etag", format!("\"{}\"", part.etag))
                                .header("x-amz-checksum-sha256", BASE64.encode(part.sha256))
                        })
                        .map_err(|error| error.to_s3())
                }
            }
            BodySink::Buffered(body) => {
                self.dispatch(&session.role, &session.operation, &session.headers, body)
            }
        };
        match response {
            Ok(mut response) => {
                if session.operation.streams_object_body() {
                    add_provided_checksum_headers(
                        &mut response,
                        &session.expected_checksums,
                        &actual_digests,
                    );
                }
                session.active = false;
                response.finalize(&session.request_id, session.operation.is_head())
            }
            Err(error) => self.fail_session(session, error),
        }
    }

    pub(crate) fn abort_body(&mut self, session: &mut BodySession) {
        self.cleanup(session);
        session.active = false;
    }

    fn authorize(&mut self, request: &RequestHead) -> Result<(String, VerifiedSignature), S3Error> {
        let has_header = request.headers.get("authorization").is_some();
        let has_query = request.target.query.get("X-Amz-Algorithm").is_some();
        if has_header == has_query {
            return Err(if has_header {
                S3Error::invalid_request("header and query authentication cannot be combined")
            } else {
                S3Error::access_denied()
            });
        }
        let access_key = if has_header {
            parse_header_authorization(&request.headers)
                .map_err(sigv4_error)?
                .credential
                .access_key
        } else {
            parse_presigned_authorization(&request.target.query)
                .map_err(sigv4_error)?
                .credential
                .access_key
        };
        // This lookup occurs as the dedicated server role. The claimed key is
        // only a selector; no tenant role is assumed until the signature has
        // verified with the selected secret.
        let credential = self
            .database
            .lookup_credential(&access_key)
            .map_err(|error| error.to_s3())?
            .ok_or_else(|| {
                S3Error::new(
                    403,
                    "InvalidAccessKeyId",
                    "The AWS access key does not exist",
                )
            })?;
        let verification = VerificationConfig {
            now: SystemTime::now(),
            max_clock_skew: self.config.max_clock_skew,
            expected_region: self.config.expected_region.clone(),
            expected_service: "s3".to_owned(),
        };
        let wire_request = SigV4Request::from(request);
        let verified = if has_header {
            verify_header(&wire_request, credential.secret.as_bytes(), &verification)
        } else {
            verify_presigned(&wire_request, credential.secret.as_bytes(), &verification)
        }
        .map_err(sigv4_error)?;
        if verified.security_token.is_some() {
            return Err(S3Error::new(
                403,
                "InvalidToken",
                "Session credentials are not configured for this access key",
            ));
        }
        Ok((credential.role, verified))
    }

    fn prepare(
        &mut self,
        request: RequestHead,
        operation: Operation,
        role: String,
        verified: VerifiedSignature,
        request_id: String,
        resource: String,
    ) -> Result<HeadOutcome, S3Error> {
        if request
            .content_length
            .is_some_and(|length| length > self.config.max_object_bytes)
        {
            return Err(S3Error::new(
                400,
                "EntityTooLarge",
                "Request entity is too large",
            ));
        }
        let has_body = operation.streams_object_body()
            || operation.requires_xml_body()
            || request.content_length.unwrap_or_default() > 0
            || request.transfer_chunked
            || matches!(
                verified.payload_mode,
                PayloadMode::StreamingSigned | PayloadMode::StreamingUnsignedTrailer
            );
        // CompleteMultipartUpload's x-amz-checksum-sha256 is the composite of
        // its raw part digests, not a checksum of the XML request entity.  It
        // is parsed and validated against stored parts in dispatch instead of
        // flowing through the generic body checksum path.
        let expected_checksums = if matches!(operation, Operation::CompleteMultipartUpload { .. }) {
            ExpectedChecksums::default()
        } else {
            expected_checksums(&request.headers, &verified.payload_mode)?
        };
        if !has_body {
            let digests = BodyDigests::for_expected(&expected_checksums);
            verify_digests(&verified.payload_mode, &digests, &expected_checksums)?;
            let response = self.dispatch(&role, &operation, &request.headers, &[])?;
            return Ok(HeadOutcome::Immediate(
                response.finalize(&request_id, operation.is_head()),
            ));
        }

        let decoder = make_decoder(&request.headers, &verified, &self.config)?;
        let digests = BodyDigests::for_expected(&expected_checksums);
        let expected_sha256 =
            expected_checksums
                .sha256
                .as_deref()
                .or(match &verified.payload_mode {
                    PayloadMode::FullHash(hash) => Some(hash.as_slice()),
                    _ => None,
                });
        let direct_put = direct_put_eligible(
            request.content_length,
            request.transfer_chunked,
            decoder.is_some(),
            request.headers.get("expect").is_some(),
            self.config.direct_put_bytes,
        );
        let sink = match &operation {
            Operation::PutObject { bucket, key } => {
                let content_type = content_type(&request.headers)?
                    .unwrap_or_else(|| "application/octet-stream".to_owned());
                let meta_json = put_metadata_json(&request.headers, &expected_checksums)?;
                let if_none_match = one_header(&request.headers, "if-none-match")?;
                let if_match = one_header(&request.headers, "if-match")?;
                if direct_put {
                    BodySink::DirectPut {
                        bucket: bucket.clone(),
                        key: key.clone(),
                        content_type,
                        meta_json,
                        if_none_match,
                        if_match,
                        expected_sha256: expected_sha256.map(<[u8]>::to_vec),
                        max_body_bytes: self.config.direct_put_bytes,
                        body: Vec::with_capacity(
                            request.content_length.unwrap_or_default() as usize
                        ),
                    }
                } else {
                    let upload_id = self
                        .database
                        .begin_upload(
                            &role,
                            bucket,
                            key,
                            &content_type,
                            // At this point ExpectedChecksums contains direct
                            // request headers only. Trailer values arrive after
                            // the streamed body and remain authoritative for body
                            // verification, but cannot be represented as a
                            // header-supplied stored object checksum.
                            &meta_json,
                            false,
                            if_none_match.as_deref(),
                            if_match.as_deref(),
                            expected_sha256,
                        )
                        .map_err(|error| error.to_s3())?;
                    BodySink::Staged {
                        bucket: bucket.clone(),
                        key: key.clone(),
                        upload_id,
                        part_number: 0,
                        sequence: 0,
                        staging_chunk_bytes: self.config.staging_chunk_bytes,
                        // Grow with received bytes so an authenticated slow
                        // peer cannot reserve a full multi-MiB chunk merely by
                        // sending a request head.  The first committed buffer
                        // is then reused for later chunks of this request.
                        buffer: Vec::new(),
                        chunk_blob_ids: Vec::new(),
                        chunk_sizes: Vec::new(),
                    }
                }
            }
            Operation::UploadPart {
                bucket,
                key,
                upload_id,
                part_number,
            } => {
                self.database
                    .begin_part(&role, bucket, key, upload_id, *part_number)
                    .map_err(|error| error.to_s3())?;
                BodySink::Staged {
                    bucket: bucket.clone(),
                    key: key.clone(),
                    upload_id: upload_id.clone(),
                    part_number: *part_number,
                    sequence: 0,
                    staging_chunk_bytes: self.config.staging_chunk_bytes,
                    buffer: Vec::new(),
                    chunk_blob_ids: Vec::new(),
                    chunk_sizes: Vec::new(),
                }
            }
            _ => BodySink::Buffered(Vec::new()),
        };
        let lease_heartbeat = match &sink {
            BodySink::Staged { .. } => Some(UploadLeaseHeartbeat::new(Instant::now())),
            BodySink::DirectPut { .. } | BodySink::Buffered(_) => None,
        };
        Ok(HeadOutcome::ReceiveBody(Box::new(BodySession {
            request_id,
            resource,
            role,
            operation,
            headers: request.headers,
            payload_mode: verified.payload_mode,
            decoder,
            sink,
            digests,
            expected_checksums,
            expected_wire_bytes: request.content_length,
            wire_bytes: 0,
            decoded_bytes: 0,
            max_decoded_bytes: self.config.max_object_bytes,
            lease_heartbeat,
            active: true,
        })))
    }

    fn renew_upload_lease_if_due(
        &mut self,
        session: &mut BodySession,
        now: Instant,
    ) -> Result<(), DbError> {
        let BodySession {
            role,
            sink,
            lease_heartbeat,
            ..
        } = session;
        let Some(heartbeat) = lease_heartbeat.as_mut() else {
            return Ok(());
        };
        let BodySink::Staged {
            bucket,
            key,
            upload_id,
            part_number,
            ..
        } = sink
        else {
            debug_assert!(false, "only staged bodies have upload lease heartbeats");
            return Ok(());
        };
        heartbeat
            .renew_if_due(now, || {
                self.database
                    .renew_upload(role, bucket, key, upload_id, *part_number != 0)
            })
            .map(|_| ())
    }

    fn accept_decoded(&mut self, session: &mut BodySession, decoded: &[u8]) -> Result<(), S3Error> {
        let count = u64::try_from(decoded.len()).unwrap_or(u64::MAX);
        session.decoded_bytes = session
            .decoded_bytes
            .checked_add(count)
            .ok_or_else(|| S3Error::new(400, "EntityTooLarge", "Decoded body is too large"))?;
        if session.decoded_bytes > session.max_decoded_bytes {
            return Err(S3Error::new(
                400,
                "EntityTooLarge",
                "Decoded body is too large",
            ));
        }
        session.digests.update(decoded);
        let fixed_body_complete =
            session.decoder.is_none() && session.expected_wire_bytes == Some(session.wire_bytes);
        let role = &session.role;
        let (sink, lease_heartbeat) = (&mut session.sink, &mut session.lease_heartbeat);
        match sink {
            BodySink::DirectPut {
                max_body_bytes,
                body,
                ..
            } => {
                append_direct_body(body, decoded, *max_body_bytes)?;
            }
            BodySink::Buffered(body) => {
                if body.len().saturating_add(decoded.len()) > self.config.max_control_body_bytes {
                    return Err(S3Error::new(
                        400,
                        "EntityTooLarge",
                        "Control request body is too large",
                    ));
                }
                body.extend_from_slice(decoded);
            }
            BodySink::Staged {
                bucket,
                key,
                upload_id,
                part_number,
                sequence,
                staging_chunk_bytes,
                buffer,
                chunk_blob_ids,
                chunk_sizes,
            } => {
                let mut remaining = decoded;
                while !remaining.is_empty() {
                    if append_staged_slice(buffer, &mut remaining, *staging_chunk_bytes) {
                        // For a fixed-length non-multipart body, retain the
                        // exact final full chunk until finish_body verifies the
                        // request digest.  It can then be stored and published
                        // under one upload-row lock and one durable transaction.
                        if *part_number == 0 && fixed_body_complete && remaining.is_empty() {
                            break;
                        }
                        let mut data = std::mem::take(buffer);
                        if *part_number == 0 {
                            let chunk_sha256 = Sha256::digest(&data);
                            let chunk = self
                                .database
                                .put_chunk_sealed(
                                    role,
                                    bucket,
                                    key,
                                    upload_id,
                                    *sequence,
                                    &data,
                                    &chunk_sha256,
                                )
                                .map_err(|error| error.to_s3())?;
                            chunk_blob_ids.push(chunk.blob_id);
                            chunk_sizes.push(chunk.size);
                        } else {
                            self.database
                                .put_chunk(
                                    role,
                                    bucket,
                                    key,
                                    upload_id,
                                    *sequence,
                                    &data,
                                    *part_number,
                                )
                                .map_err(|error| error.to_s3())?;
                        }
                        data.clear();
                        *buffer = data;
                        if let Some(heartbeat) = lease_heartbeat.as_mut() {
                            heartbeat.touched(Instant::now());
                        }
                        *sequence = sequence.checked_add(1).ok_or_else(|| {
                            S3Error::new(400, "EntityTooLarge", "Object has too many chunks")
                        })?;
                    }
                }
            }
        }
        Ok(())
    }

    fn dispatch(
        &mut self,
        role: &str,
        operation: &Operation,
        headers: &HeaderMap,
        body: &[u8],
    ) -> Result<ServiceResponse, S3Error> {
        match operation {
            Operation::ListBuckets => {
                let buckets = self
                    .database
                    .list_buckets(role)
                    .map_err(|error| error.to_s3())?;
                let dates: Vec<_> = buckets
                    .iter()
                    .map(|bucket| xml::iso8601(bucket.created_ms))
                    .collect();
                let descriptions: Vec<_> = buckets
                    .iter()
                    .zip(&dates)
                    .map(|(bucket, date)| BucketDescription {
                        name: &bucket.name,
                        creation_date: date,
                    })
                    .collect();
                Ok(ServiceResponse::xml(
                    200,
                    serialize_list_buckets(role, role, &descriptions),
                ))
            }
            Operation::CreateBucket { bucket } => {
                let region = parse_create_bucket_region(body)?;
                self.database
                    .create_bucket(role, bucket, &region)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::empty(200).header("location", format!("/{bucket}")))
            }
            Operation::DeleteBucket { bucket } => {
                self.database
                    .delete_bucket(role, bucket)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::empty(204))
            }
            Operation::HeadBucket { bucket } => {
                self.database
                    .head_bucket(role, bucket)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::empty(200))
            }
            Operation::GetBucketLocation { bucket } => {
                let region = self
                    .database
                    .bucket_location(role, bucket)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::xml(
                    200,
                    serialize_bucket_location((region != "us-east-1").then_some(region.as_str())),
                ))
            }
            Operation::GetBucketVersioning { bucket } => {
                self.database
                    .head_bucket(role, bucket)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::xml(200, serialize_versioning_enabled()))
            }
            Operation::ListObjectsV1 { bucket, params } => {
                let records = self
                    .database
                    .list_objects(role, bucket, params, false)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::xml(
                    200,
                    xml::list_objects_v1(bucket, params, &records),
                ))
            }
            Operation::ListObjectsV2 { bucket, params } => {
                let records = self
                    .database
                    .list_objects(role, bucket, params, true)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::xml(
                    200,
                    xml::list_objects_v2(bucket, params, &records),
                ))
            }
            Operation::ListObjectVersions { bucket, params } => {
                let records = self
                    .database
                    .list_versions(role, bucket, params)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::xml(
                    200,
                    xml::list_versions(bucket, params, &records),
                ))
            }
            Operation::GetObject {
                bucket,
                key,
                version_id,
            } => self.get_or_head(role, bucket, key, *version_id, headers, false),
            Operation::HeadObject {
                bucket,
                key,
                version_id,
            } => self.get_or_head(role, bucket, key, *version_id, headers, true),
            Operation::DeleteObject {
                bucket,
                key,
                version_id,
            } => {
                let deleted = self
                    .database
                    .delete_object(role, bucket, key, *version_id)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::empty(204)
                    .header("x-amz-version-id", deleted.version_id.to_string())
                    .header("x-amz-delete-marker", deleted.delete_marker.to_string()))
            }
            Operation::DeleteObjects { bucket } => self.delete_objects(role, bucket, body),
            Operation::CopyObject {
                bucket,
                key,
                source,
            } => {
                let replace = match one_header(headers, "x-amz-metadata-directive")?.as_deref() {
                    None | Some("COPY") => false,
                    Some("REPLACE") => true,
                    Some(_) => {
                        return Err(S3Error::new(
                            400,
                            "InvalidArgument",
                            "x-amz-metadata-directive must be COPY or REPLACE",
                        ));
                    }
                };
                validate_copy_destination(&source.bucket, &source.key, bucket, key, replace)?;
                let meta = replace.then(|| metadata_json(headers)).transpose()?;
                let content_type = if replace {
                    content_type(headers)?
                } else {
                    None
                };
                let mut source_version_id = source.version_id;
                let mut guarded_source_etag = one_header(headers, "x-amz-copy-source-if-match")?;
                if has_copy_source_conditions(headers) {
                    let source_info = self
                        .database
                        .head_object(role, &source.bucket, &source.key, source.version_id)
                        .map_err(|error| error.to_s3())?;
                    evaluate_copy_source_conditions(headers, &source_info)?;
                    source_version_id = Some(source_info.version_id);
                    guarded_source_etag = Some(source_info.etag);
                }
                let copied = self
                    .database
                    .copy_object(
                        role,
                        &source.bucket,
                        &source.key,
                        bucket,
                        key,
                        source_version_id,
                        content_type.as_deref(),
                        meta.as_deref(),
                        one_header(headers, "if-none-match")?.as_deref(),
                        one_header(headers, "if-match")?.as_deref(),
                        guarded_source_etag.as_deref(),
                    )
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::xml(
                    200,
                    serialize_copy_result(
                        &xml::iso8601(copied.created_ms),
                        &format!("\"{}\"", copied.etag),
                        Some(&BASE64.encode(&copied.sha256)),
                    ),
                )
                .header("x-amz-version-id", copied.version_id.to_string()))
            }
            Operation::RestoreObject {
                bucket,
                key,
                version_id,
            } => {
                let restored = self
                    .database
                    .restore_object(
                        role,
                        bucket,
                        key,
                        *version_id,
                        one_header(headers, "if-match")?.as_deref(),
                    )
                    .map_err(|error| error.to_s3())?;
                Ok(put_response(&restored))
            }
            Operation::CreateMultipartUpload { bucket, key } => {
                let checksum_algorithm = multipart_checksum_algorithm(headers)?;
                let upload_id = self
                    .database
                    .begin_upload(
                        role,
                        bucket,
                        key,
                        content_type(headers)?
                            .as_deref()
                            .unwrap_or("application/octet-stream"),
                        &multipart_metadata_json(headers, checksum_algorithm)?,
                        true,
                        one_header(headers, "if-none-match")?.as_deref(),
                        one_header(headers, "if-match")?.as_deref(),
                        None,
                    )
                    .map_err(|error| error.to_s3())?;
                Ok(initiate_multipart_response(
                    bucket,
                    key,
                    &upload_id,
                    checksum_algorithm,
                ))
            }
            Operation::CompleteMultipartUpload {
                bucket,
                key,
                upload_id,
            } => {
                let completed = parse_complete_multipart(body, self.config.xml_limits)
                    .map_err(|error| S3Error::new(400, "MalformedXML", error.to_string()))?;
                let parts: Vec<_> = completed
                    .parts
                    .iter()
                    .map(|part| i32::from(part.part_number))
                    .collect();
                let etags: Vec<_> = completed
                    .parts
                    .iter()
                    .map(|part| part.etag.clone())
                    .collect();
                let stored_algorithm = self
                    .database
                    .multipart_checksum_algorithm(role, bucket, key, upload_id)
                    .map_err(|error| error.to_s3())?;
                let sha256_completion = match stored_algorithm.as_deref() {
                    Some("SHA256") => {
                        let stored_parts = self
                            .database
                            .list_parts(role, bucket, key, upload_id)
                            .map_err(|error| error.to_s3())?;
                        Some(validate_multipart_sha256_completion(
                            &completed,
                            &stored_parts,
                            one_header(headers, "x-amz-checksum-sha256")?.as_deref(),
                        )?)
                    }
                    None => {
                        if headers.get("x-amz-checksum-sha256").is_some()
                            || completed
                                .parts
                                .iter()
                                .any(|part| part.checksums.sha256.is_some())
                        {
                            return Err(multipart_bad_digest());
                        }
                        None
                    }
                    Some(_) => {
                        return Err(S3Error::new(
                            501,
                            "NotImplemented",
                            "The stored multipart checksum algorithm is not implemented",
                        ));
                    }
                };
                let info = self
                    .database
                    .complete_multipart(
                        role,
                        bucket,
                        key,
                        upload_id,
                        &parts,
                        &etags,
                        None,
                        sha256_completion
                            .as_ref()
                            .map(|completion| completion.part_sha256s.as_slice()),
                        sha256_completion
                            .as_ref()
                            .map(|completion| completion.composite.as_str()),
                    )
                    .map_err(|error| error.to_s3())?;
                let mut response = ServiceResponse::xml(
                    200,
                    serialize_complete_multipart(
                        &format!("/{bucket}/{key}"),
                        bucket,
                        key,
                        &format!("\"{}\"", info.etag),
                        sha256_completion
                            .as_ref()
                            .map(|completion| completion.composite.as_str()),
                        sha256_completion.as_ref().map(|_| CHECKSUM_TYPE_COMPOSITE),
                    ),
                )
                .header("x-amz-version-id", info.version_id.to_string());
                if let Some(completion) = sha256_completion {
                    response = response
                        .header("x-amz-checksum-sha256", completion.composite)
                        .header("x-amz-checksum-type", CHECKSUM_TYPE_COMPOSITE);
                }
                Ok(response)
            }
            Operation::AbortMultipartUpload {
                bucket,
                key,
                upload_id,
            } => {
                self.database
                    .abort_upload(role, bucket, key, upload_id, true)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::empty(204))
            }
            Operation::ListParts {
                bucket,
                key,
                upload_id,
                params:
                    ListPartsParams {
                        part_number_marker,
                        max_parts,
                    },
            } => {
                let parts = self
                    .database
                    .list_parts(role, bucket, key, upload_id)
                    .map_err(|error| error.to_s3())?;
                Ok(ServiceResponse::xml(
                    200,
                    xml::list_parts(
                        bucket,
                        key,
                        upload_id,
                        *part_number_marker,
                        *max_parts,
                        &parts,
                    ),
                ))
            }
            Operation::PutObject { .. } | Operation::UploadPart { .. } => Err(S3Error::internal()),
        }
    }

    fn get_or_head(
        &mut self,
        role: &str,
        bucket: &str,
        key: &str,
        version_id: Option<i64>,
        headers: &HeaderMap,
        head_only: bool,
    ) -> Result<ServiceResponse, S3Error> {
        // The common unconditional GET can use pgs3.get() as the single
        // metadata+body request transaction.  The general path below needs a
        // separate HEAD for RFC preconditions, ranges, checksum-mode response
        // selection, and delete-marker HEAD headers.  Paying that cost for an
        // ordinary GET caused three object lookups across two tenant
        // transactions because pgs3.get() already resolves its own head row.
        if unconditional_get_fast_path(headers, head_only) {
            let data = self
                .database
                .get_object(role, bucket, key, version_id)
                .map_err(|error| error.to_s3())?;
            return Ok(object_headers(
                ServiceResponse {
                    status: 200,
                    headers: Vec::new(),
                    body: data.body,
                },
                &data.info,
                false,
            ));
        }

        let info = match self.database.head_object(role, bucket, key, version_id) {
            Ok(info) => info,
            Err(database_error) => {
                let error = database_error.to_s3();
                if should_probe_current_delete_marker(head_only, version_id, &error)
                    && let Some(marker) = self
                        .database
                        .current_delete_marker(role, bucket, key)
                        .map_err(|probe_error| probe_error.to_s3())?
                {
                    return Ok(delete_marker_head_response(&marker));
                }
                return Err(error);
            }
        };
        let checksum_mode = checksum_mode_enabled(headers)?;
        let etag = EntityTag {
            weak: false,
            opaque: info.etag.as_bytes().to_vec(),
        };
        let last_modified = xml::system_time(info.created_ms);
        let conditions = ConditionalHeaders::parse(headers)
            .map_err(|error| S3Error::invalid_request(error.to_string()))?;
        match conditions.evaluate(Some(&etag), Some(last_modified), true) {
            PreconditionResult::NotModified => {
                return Ok(object_headers(
                    ServiceResponse::empty(304),
                    &info,
                    checksum_mode,
                ));
            }
            PreconditionResult::PreconditionFailed => {
                return Err(S3Error::new(
                    412,
                    "PreconditionFailed",
                    "A retrieval precondition failed",
                ));
            }
            PreconditionResult::Proceed => {}
        }

        let ranges: Vec<_> = headers.get_all("range").collect();
        if ranges.len() > 1 {
            return Err(S3Error::invalid_request("Range must appear once"));
        }
        let mut resolved = ranges
            .first()
            .map(|value| ByteRangeSpec::parse(value))
            .transpose()
            .map_err(|error| S3Error::new(416, "InvalidRange", error.to_string()))?
            .map(|range| range.resolve(info.size as u64))
            .transpose()
            .map_err(|error| S3Error::new(416, "InvalidRange", error.to_string()))?;
        let if_ranges: Vec<_> = headers.get_all("if-range").collect();
        if if_ranges.len() > 1 {
            return Err(S3Error::invalid_request("If-Range must appear once"));
        }
        if let (Some(value), Some(_)) = (if_ranges.first(), resolved) {
            let condition = IfRange::parse(value)
                .map_err(|error| S3Error::invalid_request(error.to_string()))?;
            if !condition.permits_range(&etag, last_modified) {
                resolved = None;
            }
        }
        if let Some(range) = resolved {
            let body = if head_only {
                Vec::new()
            } else {
                self.database
                    .get_range(
                        role,
                        bucket,
                        key,
                        info.version_id,
                        range.start as i64,
                        range.end as i64,
                    )
                    .map_err(|error| error.to_s3())?
            };
            return Ok(object_headers(
                ServiceResponse {
                    status: 206,
                    headers: vec![
                        (
                            "content-range".into(),
                            format!("bytes {}-{}/{}", range.start, range.end, info.size),
                        ),
                        ("content-length".into(), range.len().to_string()),
                    ],
                    body,
                },
                &info,
                checksum_mode,
            ));
        }
        if head_only {
            Ok(object_headers(
                ServiceResponse::empty(200).header("content-length", info.size.to_string()),
                &info,
                checksum_mode,
            ))
        } else {
            let data = self
                .database
                .get_object(role, bucket, key, Some(info.version_id))
                .map_err(|error| error.to_s3())?;
            Ok(object_headers(
                ServiceResponse {
                    status: 200,
                    headers: Vec::new(),
                    body: data.body,
                },
                &data.info,
                checksum_mode,
            ))
        }
    }

    fn delete_objects(
        &mut self,
        role: &str,
        bucket: &str,
        body: &[u8],
    ) -> Result<ServiceResponse, S3Error> {
        let request = parse_delete_objects(body, self.config.xml_limits)
            .map_err(|error| S3Error::new(400, "MalformedXML", error.to_string()))?;
        let targets: Result<Vec<_>, _> = request
            .objects
            .iter()
            .map(|object| {
                Ok(DeleteTarget {
                    key: object.key.clone(),
                    version_id: parse_optional_version(object.version_id.as_deref())?,
                })
            })
            .collect();
        let targets = targets?;
        let results = self
            .database
            .delete_many(role, bucket, &targets)
            .map_err(|error| error.to_s3())?;

        let mut deleted_owned = Vec::new();
        let mut errors_owned = Vec::new();
        for (target, result) in targets.iter().zip(results) {
            match result {
                Ok(deleted) if !request.quiet => {
                    let (version, marker, marker_version) =
                        deleted_response_fields(target, &deleted);
                    deleted_owned.push((target.key.clone(), version, marker, marker_version));
                }
                Ok(_) => {}
                Err(error) => {
                    let mapped = error.to_s3();
                    errors_owned.push((
                        target.key.clone(),
                        target.version_id.map(|value| value.to_string()),
                        mapped.code,
                        mapped.message,
                    ));
                }
            }
        }
        let deleted: Vec<_> = deleted_owned
            .iter()
            .map(|(key, version, marker, marker_version)| DeletedObject {
                key,
                version_id: version.as_deref(),
                delete_marker: *marker,
                delete_marker_version_id: marker_version.as_deref(),
            })
            .collect();
        let errors: Vec<_> = errors_owned
            .iter()
            .map(|(key, version, code, message)| DeleteObjectError {
                key,
                version_id: version.as_deref(),
                code,
                message,
            })
            .collect();
        Ok(ServiceResponse::xml(
            200,
            serialize_delete_result(&deleted, &errors),
        ))
    }

    fn fail_session(&mut self, session: &mut BodySession, error: S3Error) -> ServiceResponse {
        self.cleanup(session);
        session.active = false;
        self.session_error(session, error)
    }

    fn session_error(&self, session: &BodySession, error: S3Error) -> ServiceResponse {
        error
            .response(&session.resource, &session.request_id)
            .finalize(&session.request_id, session.operation.is_head())
    }

    fn cleanup(&mut self, session: &BodySession) {
        let BodySink::Staged {
            bucket,
            key,
            upload_id,
            part_number,
            ..
        } = &session.sink
        else {
            return;
        };
        if *part_number == 0 {
            let _ = self
                .database
                .abort_upload(&session.role, bucket, key, upload_id, false);
        } else {
            let _ = self
                .database
                .abort_part(&session.role, bucket, key, upload_id, *part_number);
        }
    }
}

fn make_decoder(
    headers: &HeaderMap,
    verified: &VerifiedSignature,
    config: &ServiceConfig,
) -> Result<Option<AwsChunkedDecoder>, S3Error> {
    let mode = match verified.payload_mode {
        PayloadMode::StreamingSigned => AwsChunkedMode::Signed(
            verified
                .streaming_context
                .clone()
                .ok_or_else(S3Error::internal)?,
        ),
        PayloadMode::StreamingUnsignedTrailer => {
            let trailers = one_header(headers, "x-amz-trailer")?
                .ok_or_else(|| S3Error::invalid_request("x-amz-trailer is required"))?
                .split(',')
                .map(|name| name.trim().to_ascii_lowercase())
                .filter(|name| !name.is_empty())
                .collect();
            AwsChunkedMode::UnsignedTrailer {
                declared_trailers: trailers,
            }
        }
        _ => return Ok(None),
    };
    let content_encoding = one_header(headers, "content-encoding")?.unwrap_or_default();
    if !content_encoding
        .split(',')
        .any(|value| value.trim().eq_ignore_ascii_case("aws-chunked"))
    {
        return Err(S3Error::invalid_request(
            "a streaming payload requires Content-Encoding: aws-chunked",
        ));
    }
    let expected_decoded_length = one_header(headers, "x-amz-decoded-content-length")?
        .map(|value| {
            value
                .parse::<u64>()
                .map_err(|_| S3Error::invalid_request("invalid x-amz-decoded-content-length"))
        })
        .transpose()?;
    let limits = ChunkedLimits {
        max_decoded_bytes: config.max_object_bytes,
        expected_decoded_length,
        ..ChunkedLimits::default()
    };
    AwsChunkedDecoder::new(mode, limits)
        .map(Some)
        .map_err(|error| S3Error::invalid_request(error.to_string()))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum ChecksumAlgorithm {
    Crc32,
    Crc32c,
    Sha1,
    Sha256,
    Crc64Nvme,
}

impl ChecksumAlgorithm {
    const ALL: [Self; 5] = [
        Self::Crc32,
        Self::Crc32c,
        Self::Sha1,
        Self::Sha256,
        Self::Crc64Nvme,
    ];

    fn parse(value: &str, header_name: &str) -> Result<Self, S3Error> {
        match value.trim().to_ascii_uppercase().as_str() {
            "CRC32" => Ok(Self::Crc32),
            "CRC32C" => Ok(Self::Crc32c),
            "SHA1" => Ok(Self::Sha1),
            "SHA256" => Ok(Self::Sha256),
            "CRC64NVME" => Ok(Self::Crc64Nvme),
            _ => Err(S3Error::new(
                400,
                "InvalidArgument",
                format!("{header_name} names an unsupported checksum algorithm"),
            )),
        }
    }

    fn checksum_header(self) -> &'static str {
        match self {
            Self::Crc32 => "x-amz-checksum-crc32",
            Self::Crc32c => "x-amz-checksum-crc32c",
            Self::Sha1 => "x-amz-checksum-sha1",
            Self::Sha256 => "x-amz-checksum-sha256",
            Self::Crc64Nvme => "x-amz-checksum-crc64nvme",
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Crc32 => "CRC32",
            Self::Crc32c => "CRC32C",
            Self::Sha1 => "SHA1",
            Self::Sha256 => "SHA256",
            Self::Crc64Nvme => "CRC64NVME",
        }
    }

    fn decoded_length(self) -> usize {
        match self {
            Self::Crc32 | Self::Crc32c => 4,
            Self::Sha1 => 20,
            Self::Sha256 => 32,
            Self::Crc64Nvme => 8,
        }
    }

    fn from_checksum_header(name: &str) -> Option<Self> {
        match name {
            "x-amz-checksum-crc32" => Some(Self::Crc32),
            "x-amz-checksum-crc32c" => Some(Self::Crc32c),
            "x-amz-checksum-sha1" => Some(Self::Sha1),
            "x-amz-checksum-sha256" => Some(Self::Sha256),
            "x-amz-checksum-crc64nvme" => Some(Self::Crc64Nvme),
            _ => None,
        }
    }

    fn stored_meta_key(self) -> &'static str {
        match self {
            Self::Crc32 => STORED_CHECKSUM_CRC32,
            Self::Crc32c => STORED_CHECKSUM_CRC32C,
            Self::Sha1 => STORED_CHECKSUM_SHA1,
            Self::Sha256 => STORED_CHECKSUM_SHA256,
            Self::Crc64Nvme => STORED_CHECKSUM_CRC64NVME,
        }
    }

    fn from_stored_meta_key(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|algorithm| algorithm.stored_meta_key() == name)
    }
}

fn expected_checksums(
    headers: &HeaderMap,
    payload_mode: &PayloadMode,
) -> Result<ExpectedChecksums, S3Error> {
    let mut expected = ExpectedChecksums {
        content_md5: checksum_header(headers, "content-md5", 16)?,
        sha256: checksum_header(headers, "x-amz-checksum-sha256", 32)?,
        sha1: checksum_header(headers, "x-amz-checksum-sha1", 20)?,
        crc32: checksum_header(headers, "x-amz-checksum-crc32", 4)?,
        crc32c: checksum_header(headers, "x-amz-checksum-crc32c", 4)?,
        crc64nvme: checksum_header(headers, "x-amz-checksum-crc64nvme", 8)?,
        declared_trailer_algorithms: Vec::new(),
    };
    let sdk_algorithm = checksum_algorithm_header(headers, "x-amz-sdk-checksum-algorithm")?;
    // This spelling selects the checksum stored for multipart/copy results;
    // unlike the SDK declaration it is not itself a checksum of this request.
    // Parsing it still rejects typos instead of silently misrepresenting
    // support to clients.
    let _selected_algorithm = checksum_algorithm_header(headers, "x-amz-checksum-algorithm")?;

    let trailer_names = if matches!(payload_mode, PayloadMode::StreamingUnsignedTrailer) {
        one_header(headers, "x-amz-trailer")?
            .map(|value| {
                value
                    .split(',')
                    .map(|name| name.trim().to_ascii_lowercase())
                    .filter(|name| !name.is_empty())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    for name in &trailer_names {
        if let Some(algorithm) = ChecksumAlgorithm::from_checksum_header(name)
            && !expected.declared_trailer_algorithms.contains(&algorithm)
        {
            expected.declared_trailer_algorithms.push(algorithm);
        }
    }
    if let Some(algorithm) = sdk_algorithm {
        require_declared_checksum(
            &expected,
            &trailer_names,
            algorithm,
            "x-amz-sdk-checksum-algorithm",
        )?;
    }
    Ok(expected)
}

fn checksum_algorithm_header(
    headers: &HeaderMap,
    name: &'static str,
) -> Result<Option<ChecksumAlgorithm>, S3Error> {
    one_header(headers, name)?
        .map(|value| ChecksumAlgorithm::parse(&value, name))
        .transpose()
}

fn multipart_checksum_algorithm(headers: &HeaderMap) -> Result<Option<ChecksumAlgorithm>, S3Error> {
    match checksum_algorithm_header(headers, "x-amz-checksum-algorithm")? {
        None => Ok(None),
        Some(ChecksumAlgorithm::Sha256) => Ok(Some(ChecksumAlgorithm::Sha256)),
        // AWS CLI/SDK transfer managers select CRC algorithms automatically.
        // pgs3 verifies each supplied UploadPart checksum, but it does not yet
        // persist the per-part non-SHA digest needed to publish a final
        // multipart checksum. Accept without echoing an algorithm, so the
        // client sees the explicit absence of a stored final checksum.
        Some(_) => Ok(None),
    }
}

#[derive(Debug)]
struct MultipartSha256Completion {
    part_sha256s: Vec<Vec<u8>>,
    composite: String,
}

fn validate_multipart_sha256_completion(
    completed: &CompleteMultipartUpload,
    stored_parts: &[PartRecord],
    supplied_composite: Option<&str>,
) -> Result<MultipartSha256Completion, S3Error> {
    let stored: BTreeMap<_, _> = stored_parts
        .iter()
        .map(|part| (part.part_number, part))
        .collect();
    let mut part_sha256s = Vec::with_capacity(completed.parts.len());
    let mut composite = Sha256::new();
    for part in &completed.parts {
        let stored_part = stored.get(&i32::from(part.part_number)).ok_or_else(|| {
            S3Error::new(400, "InvalidPart", "A requested multipart part is missing")
        })?;
        if stored_part.sha256.len() != 32 {
            return Err(S3Error::internal());
        }
        let supplied = part
            .checksums
            .sha256
            .as_deref()
            .ok_or_else(multipart_bad_digest)?;
        let supplied = decode_multipart_sha256(supplied)?;
        if !constant_time_eq(&supplied, &stored_part.sha256) {
            return Err(multipart_bad_digest());
        }
        composite.update(&stored_part.sha256);
        part_sha256s.push(supplied);
    }
    let actual: [u8; 32] = composite.finalize().into();
    let supplied = supplied_composite.ok_or_else(multipart_bad_digest)?;
    let supplied_digest = decode_composite_sha256(supplied, completed.parts.len())?;
    if !constant_time_eq(&actual, &supplied_digest) {
        return Err(multipart_bad_digest());
    }
    Ok(MultipartSha256Completion {
        part_sha256s,
        composite: format!("{}-{}", BASE64.encode(actual), completed.parts.len()),
    })
}

fn decode_multipart_sha256(value: &str) -> Result<Vec<u8>, S3Error> {
    let decoded = BASE64.decode(value).map_err(|_| multipart_bad_digest())?;
    if decoded.len() != 32 {
        return Err(multipart_bad_digest());
    }
    Ok(decoded)
}

fn decode_composite_sha256(value: &str, expected_parts: usize) -> Result<Vec<u8>, S3Error> {
    let (digest, count) = value.rsplit_once('-').ok_or_else(multipart_bad_digest)?;
    if count.parse::<usize>().ok() != Some(expected_parts) || expected_parts == 0 {
        return Err(multipart_bad_digest());
    }
    decode_multipart_sha256(digest)
}

fn multipart_bad_digest() -> S3Error {
    S3Error::new(
        400,
        "BadDigest",
        "The multipart SHA256 checksum did not match",
    )
}

fn require_declared_checksum(
    expected: &ExpectedChecksums,
    trailer_names: &[String],
    algorithm: ChecksumAlgorithm,
    declaration: &str,
) -> Result<(), S3Error> {
    if expected.get(algorithm).is_some()
        || trailer_names
            .iter()
            .any(|name| name == algorithm.checksum_header())
    {
        return Ok(());
    }
    let has_different_checksum = expected.any()
        || trailer_names
            .iter()
            .any(|name| ChecksumAlgorithm::from_checksum_header(name).is_some());
    if has_different_checksum {
        return Err(S3Error::new(
            400,
            "BadDigest",
            format!("{declaration} does not match the provided checksum algorithm"),
        ));
    }
    Err(S3Error::new(
        400,
        "InvalidRequest",
        format!(
            "{declaration} requires {} in a header or declared trailer",
            algorithm.checksum_header()
        ),
    ))
}

fn checksum_header(
    headers: &HeaderMap,
    name: &'static str,
    length: usize,
) -> Result<Option<Vec<u8>>, S3Error> {
    one_header(headers, name)?
        .map(|encoded| decode_checksum_value(name, &encoded, length))
        .transpose()
}

fn decode_checksum_value(name: &str, encoded: &str, length: usize) -> Result<Vec<u8>, S3Error> {
    let error_code = if name.starts_with("x-amz-checksum-") {
        "BadDigest"
    } else {
        "InvalidDigest"
    };
    let decoded = BASE64
        .decode(encoded)
        .map_err(|_| S3Error::new(400, error_code, format!("{name} is not valid base64")))?;
    if decoded.len() != length {
        return Err(S3Error::new(
            400,
            error_code,
            format!("{name} has the wrong length"),
        ));
    }
    Ok(decoded)
}

fn verify_digests(
    payload_mode: &PayloadMode,
    digests: &BodyDigests,
    expected: &ExpectedChecksums,
) -> Result<(), S3Error> {
    let actual = digests.values();
    verify_digest_values(payload_mode, &actual, expected)
}

fn verify_digest_values(
    payload_mode: &PayloadMode,
    actual: &DigestValues,
    expected: &ExpectedChecksums,
) -> Result<(), S3Error> {
    if let PayloadMode::FullHash(hash) = payload_mode
        && !constant_time_eq(hash, &actual.sha256)
    {
        return Err(S3Error::new(
            400,
            "XAmzContentSHA256Mismatch",
            "The x-amz-content-sha256 value did not match the body",
        ));
    }
    let verify_checksum = |actual: Option<&[u8]>, expected: Option<&[u8]>| {
        let Some(expected) = expected else {
            return Ok(());
        };
        let Some(actual) = actual else {
            return Err(S3Error::internal());
        };
        if !constant_time_eq(actual, expected) {
            return Err(S3Error::new(
                400,
                "BadDigest",
                "A body checksum did not match",
            ));
        }
        Ok(())
    };
    verify_checksum(Some(actual.md5.as_slice()), expected.content_md5.as_deref())?;
    verify_checksum(Some(actual.sha256.as_slice()), expected.sha256.as_deref())?;
    verify_checksum(
        actual.sha1.as_ref().map(|value| value.as_slice()),
        expected.sha1.as_deref(),
    )?;
    verify_checksum(
        actual.crc32.as_ref().map(|value| value.as_slice()),
        expected.crc32.as_deref(),
    )?;
    verify_checksum(
        actual.crc32c.as_ref().map(|value| value.as_slice()),
        expected.crc32c.as_deref(),
    )?;
    verify_checksum(
        actual.crc64nvme.as_ref().map(|value| value.as_slice()),
        expected.crc64nvme.as_deref(),
    )?;
    Ok(())
}

fn add_provided_checksum_headers(
    response: &mut ServiceResponse,
    expected: &ExpectedChecksums,
    actual: &DigestValues,
) {
    let checksums: [(ChecksumAlgorithm, Option<&[u8]>); 5] = [
        (
            ChecksumAlgorithm::Crc32,
            actual.crc32.as_ref().map(|value| value.as_slice()),
        ),
        (
            ChecksumAlgorithm::Crc32c,
            actual.crc32c.as_ref().map(|value| value.as_slice()),
        ),
        (
            ChecksumAlgorithm::Sha1,
            actual.sha1.as_ref().map(|value| value.as_slice()),
        ),
        (ChecksumAlgorithm::Sha256, Some(actual.sha256.as_slice())),
        (
            ChecksumAlgorithm::Crc64Nvme,
            actual.crc64nvme.as_ref().map(|value| value.as_slice()),
        ),
    ];
    for (algorithm, checksum) in checksums {
        if expected.get(algorithm).is_none() {
            continue;
        }
        let checksum = checksum.expect("requested checksum digest must be enabled");
        let name = algorithm.checksum_header();
        response
            .headers
            .retain(|(header_name, _)| !header_name.eq_ignore_ascii_case(name));
        response
            .headers
            .push((name.to_owned(), BASE64.encode(checksum)));
    }
}

impl ExpectedChecksums {
    fn requires_digest(&self, algorithm: ChecksumAlgorithm) -> bool {
        self.get(algorithm).is_some() || self.declared_trailer_algorithms.contains(&algorithm)
    }

    fn any(&self) -> bool {
        self.sha256.is_some()
            || self.sha1.is_some()
            || self.crc32.is_some()
            || self.crc32c.is_some()
            || self.crc64nvme.is_some()
    }

    fn get(&self, algorithm: ChecksumAlgorithm) -> Option<&[u8]> {
        match algorithm {
            ChecksumAlgorithm::Crc32 => self.crc32.as_deref(),
            ChecksumAlgorithm::Crc32c => self.crc32c.as_deref(),
            ChecksumAlgorithm::Sha1 => self.sha1.as_deref(),
            ChecksumAlgorithm::Sha256 => self.sha256.as_deref(),
            ChecksumAlgorithm::Crc64Nvme => self.crc64nvme.as_deref(),
        }
    }

    fn set(&mut self, algorithm: ChecksumAlgorithm, value: Vec<u8>) -> Result<(), S3Error> {
        let slot = match algorithm {
            ChecksumAlgorithm::Crc32 => &mut self.crc32,
            ChecksumAlgorithm::Crc32c => &mut self.crc32c,
            ChecksumAlgorithm::Sha1 => &mut self.sha1,
            ChecksumAlgorithm::Sha256 => &mut self.sha256,
            ChecksumAlgorithm::Crc64Nvme => &mut self.crc64nvme,
        };
        if slot
            .as_deref()
            .is_some_and(|header_value| !constant_time_eq(header_value, &value))
        {
            return Err(S3Error::new(
                400,
                "BadDigest",
                "The checksum header and trailer did not match",
            ));
        }
        *slot = Some(value);
        Ok(())
    }
}

fn apply_verified_trailers(
    expected: &mut ExpectedChecksums,
    trailers: &[DecodedTrailer],
) -> Result<(), S3Error> {
    for trailer in trailers {
        let algorithm = ChecksumAlgorithm::from_checksum_header(&trailer.name)
            .ok_or_else(|| S3Error::invalid_request("unsupported checksum trailer"))?;
        let value =
            decode_checksum_value(&trailer.name, &trailer.value, algorithm.decoded_length())?;
        expected.set(algorithm, value)?;
    }
    Ok(())
}

fn chunked_error(error: ChunkedError) -> S3Error {
    match error {
        ChunkedError::ChecksumMismatch(name) => S3Error::new(
            400,
            "BadDigest",
            format!("The {name} trailer did not match the body"),
        ),
        ChunkedError::InvalidChecksumEncoding(name) => S3Error::new(
            400,
            "InvalidDigest",
            format!("{name} is not a valid S3 checksum"),
        ),
        ChunkedError::DecodedBodyTooLarge | ChunkedError::ChunkTooLarge => {
            S3Error::new(400, "EntityTooLarge", "Decoded body is too large")
        }
        ChunkedError::DecodedLengthMismatch { .. }
        | ChunkedError::MissingChunkTerminator
        | ChunkedError::MissingTrailer(_) => S3Error::new(400, "IncompleteBody", error.to_string()),
        _ => S3Error::new(400, "InvalidRequest", error.to_string()),
    }
}

fn sigv4_error(error: SigV4Error) -> S3Error {
    match error {
        SigV4Error::SignatureMismatch => S3Error::new(
            403,
            "SignatureDoesNotMatch",
            "The request signature we calculated does not match",
        ),
        SigV4Error::PresignedUrlExpired => S3Error::new(403, "AccessDenied", "Request has expired"),
        SigV4Error::PresignedUrlNotYetValid | SigV4Error::RequestTimeTooSkewed => S3Error::new(
            403,
            "RequestTimeTooSkewed",
            "The difference between request time and server time is too large",
        ),
        SigV4Error::PayloadHashMismatch => S3Error::new(
            400,
            "XAmzContentSHA256Mismatch",
            "The x-amz-content-sha256 value did not match the body",
        ),
        SigV4Error::RegionMismatch | SigV4Error::ServiceMismatch => {
            S3Error::new(400, "AuthorizationHeaderMalformed", error.to_string())
        }
        _ => S3Error::new(403, "AccessDenied", error.to_string()),
    }
}

fn put_response(info: &ObjectRecord) -> ServiceResponse {
    ServiceResponse::empty(200)
        .header("etag", format!("\"{}\"", info.etag))
        .header("x-amz-version-id", info.version_id.to_string())
        .header("x-amz-checksum-sha256", BASE64.encode(&info.sha256))
}

fn initiate_multipart_response(
    bucket: &str,
    key: &str,
    upload_id: &str,
    checksum_algorithm: Option<ChecksumAlgorithm>,
) -> ServiceResponse {
    let mut response = ServiceResponse::xml(
        200,
        serialize_initiate_multipart(
            bucket,
            key,
            upload_id,
            checksum_algorithm.map(ChecksumAlgorithm::name),
            checksum_algorithm.map(|_| CHECKSUM_TYPE_COMPOSITE),
        ),
    );
    if let Some(algorithm) = checksum_algorithm {
        response = response
            .header("x-amz-checksum-algorithm", algorithm.name())
            .header("x-amz-checksum-type", CHECKSUM_TYPE_COMPOSITE);
    }
    response
}

fn direct_put_eligible(
    content_length: Option<u64>,
    transfer_chunked: bool,
    has_aws_decoder: bool,
    has_expect: bool,
    max_body_bytes: usize,
) -> bool {
    // begin_upload is the writable-standby preflight before 100 Continue, so
    // Expect requests must remain staged. Transport/AWS chunking can reveal
    // the decoded size only while consuming the body and remains staged too.
    !transfer_chunked
        && !has_aws_decoder
        && !has_expect
        && content_length
            .is_some_and(|length| length <= u64::try_from(max_body_bytes).unwrap_or(u64::MAX))
}

fn append_direct_body(
    body: &mut Vec<u8>,
    decoded: &[u8],
    max_body_bytes: usize,
) -> Result<(), S3Error> {
    if body.len().saturating_add(decoded.len()) > max_body_bytes {
        return Err(S3Error::new(
            400,
            "EntityTooLarge",
            "Direct object body exceeded its bounded buffer",
        ));
    }
    body.extend_from_slice(decoded);
    Ok(())
}

fn append_staged_slice(
    buffer: &mut Vec<u8>,
    remaining: &mut &[u8],
    staging_chunk_bytes: usize,
) -> bool {
    debug_assert!(staging_chunk_bytes > 0);
    debug_assert!(buffer.len() <= staging_chunk_bytes);
    let capacity = staging_chunk_bytes - buffer.len();
    let count = capacity.min(remaining.len());
    buffer.extend_from_slice(&remaining[..count]);
    *remaining = &remaining[count..];
    buffer.len() == staging_chunk_bytes
}

fn unconditional_get_fast_path(headers: &HeaderMap, head_only: bool) -> bool {
    !head_only
        && [
            "if-match",
            "if-none-match",
            "if-modified-since",
            "if-unmodified-since",
            "range",
            "if-range",
            "x-amz-checksum-mode",
        ]
        .into_iter()
        .all(|name| headers.get(name).is_none())
}

fn should_probe_current_delete_marker(
    head_only: bool,
    version_id: Option<i64>,
    error: &S3Error,
) -> bool {
    head_only && version_id.is_none() && error.code == "NoSuchKey"
}

fn delete_marker_head_response(marker: &DeleteMarkerRecord) -> ServiceResponse {
    ServiceResponse::empty(404)
        .header("x-amz-delete-marker", "true")
        .header("x-amz-version-id", marker.version_id.to_string())
}

fn checksum_mode_enabled(headers: &HeaderMap) -> Result<bool, S3Error> {
    match one_header(headers, "x-amz-checksum-mode")?.as_deref() {
        None => Ok(false),
        Some(value) if value.eq_ignore_ascii_case("ENABLED") => Ok(true),
        Some(_) => Err(S3Error::new(
            400,
            "InvalidArgument",
            "x-amz-checksum-mode must be ENABLED",
        )),
    }
}

fn object_headers(
    mut response: ServiceResponse,
    info: &ObjectRecord,
    checksum_mode: bool,
) -> ServiceResponse {
    // The stored checksum describes the complete object, not the selected
    // representation bytes. Advertising it on 206 makes AWS SDKs validate
    // each range against the whole-object digest; advertising it on 304 makes
    // some SDKs wrap the empty error body in a streaming checksum reader.
    let include_stored_checksums = checksum_mode && response.status == 200;
    response.headers.extend([
        ("etag".into(), format!("\"{}\"", info.etag)),
        (
            "last-modified".into(),
            httpdate::fmt_http_date(xml::system_time(info.created_ms)),
        ),
        ("x-amz-version-id".into(), info.version_id.to_string()),
        (
            "content-type".into(),
            info.content_type
                .clone()
                .unwrap_or_else(|| "application/octet-stream".into()),
        ),
        ("accept-ranges".into(), "bytes".into()),
    ]);
    for (name, value) in parse_metadata_json(&info.meta_json) {
        match name.as_str() {
            STORED_CACHE_CONTROL => response.headers.push(("cache-control".into(), value)),
            STORED_EXPIRES => response.headers.push(("expires".into(), value)),
            STORED_CONTENT_ENCODING => {
                response.headers.push(("content-encoding".into(), value));
            }
            STORED_CHECKSUM_TYPE => {
                if include_stored_checksums && value == CHECKSUM_TYPE_COMPOSITE {
                    response.headers.push(("x-amz-checksum-type".into(), value));
                }
            }
            _ if ChecksumAlgorithm::from_stored_meta_key(&name).is_some() => {
                let Some(algorithm) = ChecksumAlgorithm::from_stored_meta_key(&name) else {
                    unreachable!("match guard established stored checksum algorithm");
                };
                // Reserved values are written only after header parsing has
                // validated their base64 shape.  Revalidate on read so direct
                // SQL metadata edits cannot inject a malformed HTTP checksum.
                if include_stored_checksums && valid_stored_checksum(algorithm, &value) {
                    response
                        .headers
                        .push((algorithm.checksum_header().into(), value));
                }
            }
            _ if name.starts_with("@pgs3:") => {}
            _ => response.headers.push((format!("x-amz-meta-{name}"), value)),
        }
    }
    response
}

fn valid_stored_checksum(algorithm: ChecksumAlgorithm, value: &str) -> bool {
    if decode_checksum_value(
        algorithm.checksum_header(),
        value,
        algorithm.decoded_length(),
    )
    .is_ok()
    {
        return true;
    }
    if algorithm != ChecksumAlgorithm::Sha256 {
        return false;
    }
    let Some((_, count)) = value.rsplit_once('-') else {
        return false;
    };
    let Some(count) = count.parse::<usize>().ok().filter(|count| *count > 0) else {
        return false;
    };
    decode_composite_sha256(value, count).is_ok()
}

fn content_type(headers: &HeaderMap) -> Result<Option<String>, S3Error> {
    one_header(headers, "content-type")
}

fn one_header(headers: &HeaderMap, name: &'static str) -> Result<Option<String>, S3Error> {
    let values: Vec<_> = headers.get_all(name).collect();
    if values.len() > 1 {
        return Err(S3Error::invalid_request(format!("duplicate header {name}")));
    }
    values
        .first()
        .map(|value| {
            std::str::from_utf8(value)
                .map(str::to_owned)
                .map_err(|_| S3Error::invalid_request(format!("{name} is not UTF-8")))
        })
        .transpose()
}

fn has_copy_source_conditions(headers: &HeaderMap) -> bool {
    [
        "x-amz-copy-source-if-match",
        "x-amz-copy-source-if-none-match",
        "x-amz-copy-source-if-modified-since",
        "x-amz-copy-source-if-unmodified-since",
    ]
    .iter()
    .any(|name| headers.get(name).is_some())
}

fn validate_copy_destination(
    source_bucket: &str,
    source_key: &str,
    destination_bucket: &str,
    destination_key: &str,
    replaces_metadata: bool,
) -> Result<(), S3Error> {
    if source_bucket == destination_bucket && source_key == destination_key && !replaces_metadata {
        return Err(S3Error::invalid_request(
            "CopyObject to itself requires REPLACE metadata",
        ));
    }
    Ok(())
}

fn evaluate_copy_source_conditions(
    headers: &HeaderMap,
    source: &ObjectRecord,
) -> Result<(), S3Error> {
    let mut mapped = Vec::new();
    for (source_name, standard_name) in [
        ("x-amz-copy-source-if-match", "if-match"),
        ("x-amz-copy-source-if-none-match", "if-none-match"),
        ("x-amz-copy-source-if-modified-since", "if-modified-since"),
        (
            "x-amz-copy-source-if-unmodified-since",
            "if-unmodified-since",
        ),
    ] {
        if let Some(value) = one_header(headers, source_name)? {
            mapped.push((standard_name.to_owned(), value.into_bytes()));
        }
    }
    let mapped = HeaderMap::from_pairs(mapped)
        .map_err(|error| S3Error::invalid_request(error.to_string()))?;
    let conditions = ConditionalHeaders::parse(&mapped)
        .map_err(|error| S3Error::invalid_request(error.to_string()))?;
    let etag = EntityTag {
        weak: false,
        opaque: source.etag.as_bytes().to_vec(),
    };
    if conditions.evaluate(
        Some(&etag),
        Some(xml::system_time(source.created_ms)),
        false,
    ) == PreconditionResult::Proceed
    {
        Ok(())
    } else {
        Err(S3Error::new(
            412,
            "PreconditionFailed",
            "A CopyObject source precondition failed",
        ))
    }
}

fn parse_optional_version(value: Option<&str>) -> Result<Option<i64>, S3Error> {
    value
        .map(|value| {
            value
                .parse::<i64>()
                .ok()
                .filter(|version| *version > 0)
                .ok_or_else(|| {
                    S3Error::new(
                        400,
                        "InvalidArgument",
                        "VersionId must be a positive integer",
                    )
                })
        })
        .transpose()
}

fn deleted_response_fields(
    target: &DeleteTarget,
    deleted: &super::db::DeleteRecord,
) -> (Option<String>, bool, Option<String>) {
    (
        target.version_id.map(|value| value.to_string()),
        deleted.delete_marker,
        deleted
            .delete_marker
            .then(|| deleted.version_id.to_string()),
    )
}

fn metadata_json(headers: &HeaderMap) -> Result<String, S3Error> {
    metadata_json_inner(headers, None, None)
}

fn put_metadata_json(
    headers: &HeaderMap,
    header_checksums: &ExpectedChecksums,
) -> Result<String, S3Error> {
    metadata_json_inner(headers, Some(header_checksums), None)
}

fn multipart_metadata_json(
    headers: &HeaderMap,
    checksum_algorithm: Option<ChecksumAlgorithm>,
) -> Result<String, S3Error> {
    metadata_json_inner(headers, None, checksum_algorithm)
}

fn metadata_json_inner(
    headers: &HeaderMap,
    header_checksums: Option<&ExpectedChecksums>,
    multipart_checksum_algorithm: Option<ChecksumAlgorithm>,
) -> Result<String, S3Error> {
    let mut metadata = BTreeMap::new();
    for header in headers.fields() {
        let Some(name) = header.name.strip_prefix("x-amz-meta-") else {
            continue;
        };
        if name.is_empty() || metadata.contains_key(name) {
            return Err(S3Error::invalid_request("duplicate or empty metadata name"));
        }
        let value = std::str::from_utf8(&header.value)
            .map_err(|_| S3Error::invalid_request("metadata value is not UTF-8"))?;
        metadata.insert(name.to_owned(), value.to_owned());
    }
    for (header, key) in [
        ("cache-control", STORED_CACHE_CONTROL),
        ("expires", STORED_EXPIRES),
    ] {
        if let Some(value) = one_header(headers, header)? {
            metadata.insert(key.to_owned(), value);
        }
    }
    if let Some(value) = stored_content_encoding(headers)? {
        metadata.insert(STORED_CONTENT_ENCODING.to_owned(), value);
    }
    if let Some(checksums) = header_checksums {
        for algorithm in ChecksumAlgorithm::ALL {
            if let Some(value) = checksums.get(algorithm) {
                metadata.insert(algorithm.stored_meta_key().to_owned(), BASE64.encode(value));
            }
        }
    }
    if let Some(algorithm) = multipart_checksum_algorithm {
        metadata.insert(
            STORED_CHECKSUM_ALGORITHM.to_owned(),
            algorithm.name().to_owned(),
        );
        metadata.insert(
            STORED_CHECKSUM_TYPE.to_owned(),
            CHECKSUM_TYPE_COMPOSITE.to_owned(),
        );
    }
    let mut json = String::from("{");
    for (index, (name, value)) in metadata.iter().enumerate() {
        if index != 0 {
            json.push(',');
        }
        json_string(&mut json, name);
        json.push(':');
        json_string(&mut json, value);
    }
    json.push('}');
    Ok(json)
}

fn stored_content_encoding(headers: &HeaderMap) -> Result<Option<String>, S3Error> {
    let Some(value) = one_header(headers, "content-encoding")? else {
        return Ok(None);
    };
    let application_encodings: Vec<_> = value
        .split(',')
        .map(str::trim)
        .filter(|encoding| !encoding.is_empty() && !encoding.eq_ignore_ascii_case("aws-chunked"))
        .collect();
    Ok((!application_encodings.is_empty()).then(|| application_encodings.join(", ")))
}

fn json_string(output: &mut String, value: &str) {
    output.push('"');
    for character in value.chars() {
        match character {
            '"' => output.push_str("\\\""),
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            character if character.is_control() => {
                use std::fmt::Write;
                let _ = write!(output, "\\u{:04x}", character as u32);
            }
            character => output.push(character),
        }
    }
    output.push('"');
}

fn parse_metadata_json(input: &str) -> Vec<(String, String)> {
    // jsonb renders S3 metadata as a flat object of strings. A strict small
    // parser avoids making serde_json a public dependency of the extension;
    // non-string values inserted through SQL are intentionally not exposed as
    // HTTP metadata.
    let bytes = input.as_bytes();
    let mut index = skip_space(bytes, 0);
    if bytes.get(index) != Some(&b'{') {
        return Vec::new();
    }
    index += 1;
    let mut result = Vec::new();
    loop {
        index = skip_space(bytes, index);
        if bytes.get(index) == Some(&b'}') {
            return result;
        }
        let Some((name, next)) = parse_json_string(bytes, index) else {
            return Vec::new();
        };
        index = skip_space(bytes, next);
        if bytes.get(index) != Some(&b':') {
            return Vec::new();
        }
        index = skip_space(bytes, index + 1);
        let Some((value, next)) = parse_json_string(bytes, index) else {
            return Vec::new();
        };
        result.push((name, value));
        index = skip_space(bytes, next);
        match bytes.get(index) {
            Some(b',') => index += 1,
            Some(b'}') => return result,
            _ => return Vec::new(),
        }
    }
}

fn parse_json_string(bytes: &[u8], mut index: usize) -> Option<(String, usize)> {
    if bytes.get(index) != Some(&b'"') {
        return None;
    }
    index += 1;
    let mut output = String::new();
    while let Some(&byte) = bytes.get(index) {
        index += 1;
        match byte {
            b'"' => return Some((output, index)),
            b'\\' => {
                let escape = *bytes.get(index)?;
                index += 1;
                match escape {
                    b'"' => output.push('"'),
                    b'\\' => output.push('\\'),
                    b'/' => output.push('/'),
                    b'b' => output.push('\u{0008}'),
                    b'f' => output.push('\u{000c}'),
                    b'n' => output.push('\n'),
                    b'r' => output.push('\r'),
                    b't' => output.push('\t'),
                    b'u' => {
                        let hex = std::str::from_utf8(bytes.get(index..index + 4)?).ok()?;
                        let value = u16::from_str_radix(hex, 16).ok()?;
                        output.push(char::from_u32(u32::from(value))?);
                        index += 4;
                    }
                    _ => return None,
                }
            }
            byte if byte < 0x20 => return None,
            byte if byte.is_ascii() => output.push(char::from(byte)),
            _ => {
                let tail = std::str::from_utf8(&bytes[index - 1..]).ok()?;
                let character = tail.chars().next()?;
                output.push(character);
                index += character.len_utf8() - 1;
            }
        }
    }
    None
}

fn skip_space(bytes: &[u8], mut index: usize) -> usize {
    while bytes.get(index).is_some_and(u8::is_ascii_whitespace) {
        index += 1;
    }
    index
}

fn parse_create_bucket_region(body: &[u8]) -> Result<String, S3Error> {
    if body.is_empty() {
        return Ok("us-east-1".to_owned());
    }
    if body.len() > 64 * 1024 {
        return Err(S3Error::new(
            400,
            "MalformedXML",
            "CreateBucket XML is too large",
        ));
    }
    let mut reader = Reader::from_reader(body);
    reader.config_mut().check_end_names = true;
    reader.config_mut().expand_empty_elements = true;
    let mut in_location = false;
    let mut location = None;
    loop {
        match reader.read_event() {
            Ok(Event::Start(start)) => {
                in_location = start.local_name().as_ref() == b"LocationConstraint";
            }
            Ok(Event::Text(text)) if in_location => {
                let decoded = text
                    .xml10_content()
                    .map_err(|error| S3Error::new(400, "MalformedXML", error.to_string()))?;
                location = Some(
                    quick_xml::escape::unescape(&decoded)
                        .map_err(|error| S3Error::new(400, "MalformedXML", error.to_string()))?
                        .into_owned(),
                );
            }
            Ok(Event::End(end)) if end.local_name().as_ref() == b"LocationConstraint" => {
                in_location = false;
            }
            Ok(Event::DocType(_) | Event::PI(_)) => {
                return Err(S3Error::new(400, "MalformedXML", "forbidden XML construct"));
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(error) => return Err(S3Error::new(400, "MalformedXML", error.to_string())),
        }
    }
    location
        .filter(|region| !region.is_empty())
        .ok_or_else(|| S3Error::new(400, "MalformedXML", "LocationConstraint is required"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct MockLeaseRenewer {
        calls: usize,
        fail: bool,
    }

    impl MockLeaseRenewer {
        fn renew(&mut self) -> Result<(), &'static str> {
            self.calls += 1;
            if self.fail {
                Err("renew failed")
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn upload_lease_heartbeat_is_bounded_and_rescheduled() {
        let started = Instant::now();
        let mut heartbeat = UploadLeaseHeartbeat::new(started);
        let mut renewer = MockLeaseRenewer::default();

        assert!(
            !heartbeat
                .renew_if_due(started + Duration::from_secs(59), || renewer.renew())
                .unwrap()
        );
        assert_eq!(renewer.calls, 0);

        assert!(
            heartbeat
                .renew_if_due(started + Duration::from_secs(60), || renewer.renew())
                .unwrap()
        );
        assert_eq!(renewer.calls, 1);
        assert!(
            !heartbeat
                .renew_if_due(started + Duration::from_secs(119), || renewer.renew())
                .unwrap()
        );
        assert_eq!(renewer.calls, 1);
        assert!(
            heartbeat
                .renew_if_due(started + Duration::from_secs(120), || renewer.renew())
                .unwrap()
        );
        assert_eq!(renewer.calls, 2);
    }

    #[test]
    fn upload_lease_heartbeat_error_is_fail_closed() {
        let started = Instant::now();
        let due = started + UPLOAD_LEASE_HEARTBEAT_INTERVAL;
        let mut heartbeat = UploadLeaseHeartbeat::new(started);
        let mut renewer = MockLeaseRenewer {
            fail: true,
            ..MockLeaseRenewer::default()
        };

        assert_eq!(
            heartbeat.renew_if_due(due, || renewer.renew()).unwrap_err(),
            "renew failed"
        );
        assert_eq!(renewer.calls, 1);
        assert_eq!(
            heartbeat.next, due,
            "a failed renewal must not extend the deadline"
        );

        renewer.fail = false;
        assert!(
            heartbeat.renew_if_due(due, || renewer.renew()).unwrap(),
            "the still-due heartbeat must retry instead of silently continuing"
        );
        assert_eq!(renewer.calls, 2);
    }

    #[test]
    fn content_md5_detects_tampering_before_commit() {
        let expected = ExpectedChecksums {
            content_md5: Some(BASE64.decode("XUFAKrxLKna5cZ2REBfFkg==").unwrap()),
            ..ExpectedChecksums::default()
        };
        let mut correct = BodyDigests::default();
        correct.update(b"hello");
        assert!(verify_digests(&PayloadMode::UnsignedPayload, &correct, &expected).is_ok());
        let mut tampered = BodyDigests::default();
        tampered.update(b"jello");
        let error =
            verify_digests(&PayloadMode::UnsignedPayload, &tampered, &expected).unwrap_err();
        assert_eq!(error.code, "BadDigest");
    }

    #[test]
    fn body_digests_skip_unrequested_flexible_checksums() {
        let digests = BodyDigests::default();
        assert!(digests.sha1.is_none());
        assert!(digests.crc32.is_none());
        assert!(digests.crc32c.is_none());
        assert!(digests.crc64nvme.is_none());

        let expected = ExpectedChecksums {
            sha1: Some(vec![0; 20]),
            crc32c: Some(vec![0; 4]),
            ..ExpectedChecksums::default()
        };
        let digests = BodyDigests::for_expected(&expected);
        assert!(digests.sha1.is_some());
        assert!(digests.crc32.is_none());
        assert!(digests.crc32c.is_some());
        assert!(digests.crc64nvme.is_none());
    }

    #[test]
    fn validates_every_s3_checksum_header_over_incremental_input() {
        let headers = HeaderMap::from_pairs([
            ("x-amz-checksum-crc32", b"y/Q5Jg==".as_slice()),
            ("x-amz-checksum-crc32c", b"4waSgw==".as_slice()),
            (
                "x-amz-checksum-sha1",
                b"98O8HYCOBHMq32eZZczDTKeuNEE=".as_slice(),
            ),
            (
                "x-amz-checksum-sha256",
                b"FeKw08M4keuw8e9gnsQZQgwg4yDOlMZfvIwzEkSOsiU=".as_slice(),
            ),
            ("x-amz-checksum-crc64nvme", b"rosUhgp5mIg=".as_slice()),
        ])
        .unwrap();
        let expected = expected_checksums(&headers, &PayloadMode::UnsignedPayload).unwrap();
        let mut digests = BodyDigests::for_expected(&expected);
        for fragment in b"123456789".chunks(2) {
            digests.update(fragment);
        }
        verify_digests(&PayloadMode::UnsignedPayload, &digests, &expected).unwrap();
        let mut response = ServiceResponse::empty(200);
        let actual = digests.values();
        add_provided_checksum_headers(&mut response, &expected, &actual);
        assert_eq!(response.headers.len(), 5);
        assert!(response.headers.iter().any(|(name, value)| {
            name == "x-amz-checksum-crc64nvme" && value == "rosUhgp5mIg="
        }));

        for algorithm in [
            ChecksumAlgorithm::Crc32,
            ChecksumAlgorithm::Crc32c,
            ChecksumAlgorithm::Sha1,
            ChecksumAlgorithm::Sha256,
            ChecksumAlgorithm::Crc64Nvme,
        ] {
            let mut wrong = ExpectedChecksums::default();
            wrong
                .set(algorithm, vec![0; algorithm.decoded_length()])
                .unwrap();
            let error = verify_digests(&PayloadMode::UnsignedPayload, &digests, &wrong)
                .expect_err("a wrong client checksum must reject the request");
            assert_eq!(error.code, "BadDigest");
        }
    }

    #[test]
    fn sdk_crc64nvme_declaration_accepts_and_binds_verified_trailer() {
        let headers = HeaderMap::from_pairs([
            ("x-amz-sdk-checksum-algorithm", b"CRC64NVME".as_slice()),
            ("x-amz-trailer", b"x-amz-checksum-crc64nvme".as_slice()),
        ])
        .unwrap();
        let mut expected =
            expected_checksums(&headers, &PayloadMode::StreamingUnsignedTrailer).unwrap();
        assert!(expected.crc64nvme.is_none());
        let mut digests = BodyDigests::for_expected(&expected);
        assert!(digests.crc64nvme.is_some());
        digests.update(b"123");
        digests.update(b"456789");
        apply_verified_trailers(
            &mut expected,
            &[DecodedTrailer {
                name: "x-amz-checksum-crc64nvme".into(),
                value: "rosUhgp5mIg=".into(),
            }],
        )
        .unwrap();
        verify_digests(&PayloadMode::StreamingUnsignedTrailer, &digests, &expected).unwrap();
    }

    #[test]
    fn sdk_declaration_requires_value_while_selection_header_does_not() {
        let headers =
            HeaderMap::from_pairs([("x-amz-sdk-checksum-algorithm", b"CRC32C".as_slice())])
                .unwrap();
        let error = expected_checksums(&headers, &PayloadMode::UnsignedPayload)
            .expect_err("an SDK declaration without its checksum must be rejected");
        assert_eq!(error.code, "InvalidRequest");

        let headers = HeaderMap::from_pairs([
            ("x-amz-sdk-checksum-algorithm", b"CRC32C".as_slice()),
            (
                "x-amz-checksum-sha1",
                b"98O8HYCOBHMq32eZZczDTKeuNEE=".as_slice(),
            ),
        ])
        .unwrap();
        let error = expected_checksums(&headers, &PayloadMode::UnsignedPayload)
            .expect_err("a mismatched SDK declaration must be rejected");
        assert_eq!(error.code, "BadDigest");

        let headers = HeaderMap::from_pairs([
            ("x-amz-sdk-checksum-algorithm", b"CRC32C".as_slice()),
            ("x-amz-checksum-crc32c", b"4waSgw==".as_slice()),
        ])
        .unwrap();
        expected_checksums(&headers, &PayloadMode::UnsignedPayload).unwrap();

        let headers =
            HeaderMap::from_pairs([("x-amz-checksum-algorithm", b"CRC64NVME".as_slice())]).unwrap();
        expected_checksums(&headers, &PayloadMode::UnsignedPayload).unwrap();
    }

    #[test]
    fn conflicting_checksum_header_and_verified_trailer_is_bad_digest() {
        let mut expected = ExpectedChecksums {
            crc32c: Some(BASE64.decode("4waSgw==").unwrap()),
            ..ExpectedChecksums::default()
        };
        let error = apply_verified_trailers(
            &mut expected,
            &[DecodedTrailer {
                name: "x-amz-checksum-crc32c".into(),
                value: "AAAAAA==".into(),
            }],
        )
        .unwrap_err();
        assert_eq!(error.code, "BadDigest");
    }

    #[test]
    fn put_metadata_persists_direct_checksums_but_not_late_trailers() {
        let headers = HeaderMap::from_pairs([
            (
                "x-amz-checksum-sha256",
                b"FeKw08M4keuw8e9gnsQZQgwg4yDOlMZfvIwzEkSOsiU=".as_slice(),
            ),
            ("x-amz-trailer", b"x-amz-checksum-crc64nvme".as_slice()),
        ])
        .unwrap();
        let mut expected =
            expected_checksums(&headers, &PayloadMode::StreamingUnsignedTrailer).unwrap();

        // begin_upload receives this immutable JSON snapshot before any body
        // bytes or verified trailers arrive.
        let json = put_metadata_json(&headers, &expected).unwrap();
        let stored: BTreeMap<_, _> = parse_metadata_json(&json).into_iter().collect();
        assert_eq!(
            stored.get(STORED_CHECKSUM_SHA256).map(String::as_str),
            Some("FeKw08M4keuw8e9gnsQZQgwg4yDOlMZfvIwzEkSOsiU=")
        );
        assert!(!stored.contains_key(STORED_CHECKSUM_CRC64NVME));

        let mut valid_body = BodyDigests::for_expected(&expected);
        valid_body.update(b"123456789");
        let mut invalid_body = BodyDigests::for_expected(&expected);
        invalid_body.update(b"123456780");
        apply_verified_trailers(
            &mut expected,
            &[DecodedTrailer {
                name: "x-amz-checksum-crc64nvme".into(),
                value: "rosUhgp5mIg=".into(),
            }],
        )
        .unwrap();
        verify_digests(
            &PayloadMode::StreamingUnsignedTrailer,
            &valid_body,
            &expected,
        )
        .unwrap();
        assert_eq!(
            verify_digests(
                &PayloadMode::StreamingUnsignedTrailer,
                &invalid_body,
                &expected,
            )
            .unwrap_err()
            .code,
            "BadDigest"
        );
    }

    #[test]
    fn multipart_sha256_uses_stored_part_hashes_and_rejects_every_bad_shape() {
        let part_sha256 = "arcu6553sHVAiX4MjW0j7I7vD4w6R+Gz9Ok0Q9lTa+0=";
        let composite_sha256 = "Ok6Cs5b96ux6+MWQkJO7UBT5sKPBeXBLwvj/hK89smg=-1";
        let completed = CompleteMultipartUpload {
            parts: vec![crate::protocol::xml::CompletedPart {
                part_number: 1,
                etag: "etag".into(),
                checksums: crate::protocol::xml::PartChecksums {
                    sha256: Some(part_sha256.into()),
                    ..crate::protocol::xml::PartChecksums::default()
                },
            }],
        };
        let stored = vec![PartRecord {
            part_number: 1,
            size: 1024,
            etag: "etag".into(),
            sha256: BASE64.decode(part_sha256).unwrap(),
            completed_ms: 0,
        }];
        let validated =
            validate_multipart_sha256_completion(&completed, &stored, Some(composite_sha256))
                .unwrap();
        assert_eq!(validated.composite, composite_sha256);
        assert_eq!(validated.part_sha256s, vec![stored[0].sha256.clone()]);

        for supplied in [
            None,
            Some("bad"),
            Some("Ok6Cs5b96ux6+MWQkJO7UBT5sKPBeXBLwvj/hK89smg=-2"),
        ] {
            assert_eq!(
                validate_multipart_sha256_completion(&completed, &stored, supplied)
                    .unwrap_err()
                    .code,
                "BadDigest"
            );
        }

        let mut bad_part = completed.clone();
        bad_part.parts[0].checksums.sha256 = None;
        assert_eq!(
            validate_multipart_sha256_completion(&bad_part, &stored, Some(composite_sha256))
                .unwrap_err()
                .code,
            "BadDigest"
        );
        bad_part.parts[0].checksums.sha256 = Some(BASE64.encode([0_u8; 32]));
        assert_eq!(
            validate_multipart_sha256_completion(&bad_part, &stored, Some(composite_sha256))
                .unwrap_err()
                .code,
            "BadDigest"
        );
        assert_eq!(
            validate_multipart_sha256_completion(&completed, &[], Some(composite_sha256))
                .unwrap_err()
                .code,
            "InvalidPart"
        );
    }

    #[test]
    fn multipart_sha256_selection_and_composite_metadata_are_hidden() {
        let selected =
            HeaderMap::from_pairs([("x-amz-checksum-algorithm", b"SHA256".as_slice())]).unwrap();
        assert_eq!(
            multipart_checksum_algorithm(&selected).unwrap(),
            Some(ChecksumAlgorithm::Sha256)
        );
        let initiated = initiate_multipart_response(
            "bucket",
            "key",
            "upload-id",
            Some(ChecksumAlgorithm::Sha256),
        );
        assert!(
            initiated
                .headers
                .contains(&("x-amz-checksum-algorithm".into(), "SHA256".into()))
        );
        assert!(
            initiated
                .headers
                .contains(&("x-amz-checksum-type".into(), CHECKSUM_TYPE_COMPOSITE.into()))
        );
        let aws_cli_default =
            HeaderMap::from_pairs([("x-amz-checksum-algorithm", b"CRC32".as_slice())]).unwrap();
        assert_eq!(
            multipart_checksum_algorithm(&aws_cli_default).unwrap(),
            None
        );
        let newer_sdk_default =
            HeaderMap::from_pairs([("x-amz-checksum-algorithm", b"CRC64NVME".as_slice())]).unwrap();
        assert_eq!(
            multipart_checksum_algorithm(&newer_sdk_default).unwrap(),
            None
        );

        let metadata = multipart_metadata_json(&selected, Some(ChecksumAlgorithm::Sha256)).unwrap();
        let metadata: BTreeMap<_, _> = parse_metadata_json(&metadata).into_iter().collect();
        assert_eq!(
            metadata.get(STORED_CHECKSUM_ALGORITHM).map(String::as_str),
            Some("SHA256")
        );
        assert_eq!(
            metadata.get(STORED_CHECKSUM_TYPE).map(String::as_str),
            Some(CHECKSUM_TYPE_COMPOSITE)
        );

        let composite = "Ok6Cs5b96ux6+MWQkJO7UBT5sKPBeXBLwvj/hK89smg=-1";
        let info = ObjectRecord {
            bucket: "bucket".into(),
            key: "key".into(),
            version_id: 1,
            size: 1024,
            etag: "etag-1".into(),
            sha256: vec![7; 32],
            content_type: None,
            meta_json: format!(
                "{{\"{STORED_CHECKSUM_ALGORITHM}\":\"SHA256\",\
                   \"{STORED_CHECKSUM_SHA256}\":\"{composite}\",\
                   \"{STORED_CHECKSUM_TYPE}\":\"{CHECKSUM_TYPE_COMPOSITE}\"}}"
            ),
            created_ms: 0,
        };
        let disabled = object_headers(ServiceResponse::empty(200), &info, false);
        assert!(
            disabled
                .headers
                .iter()
                .all(|(name, _)| !name.starts_with("x-amz-checksum-"))
        );
        let enabled = object_headers(ServiceResponse::empty(200), &info, true);
        assert!(
            enabled
                .headers
                .contains(&("x-amz-checksum-sha256".into(), composite.into()))
        );
        assert!(
            enabled
                .headers
                .contains(&("x-amz-checksum-type".into(), CHECKSUM_TYPE_COMPOSITE.into()))
        );
        assert!(
            enabled
                .headers
                .iter()
                .all(|(name, _)| !name.starts_with("x-amz-meta-@pgs3:"))
        );
    }

    #[test]
    fn malformed_flexible_checksum_is_bad_digest() {
        assert_eq!(
            decode_checksum_value("x-amz-checksum-sha256", "bad", 32)
                .unwrap_err()
                .code,
            "BadDigest"
        );
        assert_eq!(
            decode_checksum_value("content-md5", "bad", 16)
                .unwrap_err()
                .code,
            "InvalidDigest"
        );
    }

    #[test]
    fn metadata_round_trips_json_escapes() {
        let headers = HeaderMap::from_pairs([
            ("x-amz-meta-agent", b"codex".as_slice()),
            ("x-amz-meta-note", b"a \\\"quote\\\"".as_slice()),
            ("cache-control", b"public, max-age=14400".as_slice()),
            ("expires", b"Sun, 06 Nov 2094 08:49:37 GMT".as_slice()),
            ("content-encoding", b"gzip, aws-chunked".as_slice()),
        ])
        .unwrap();
        let json = metadata_json(&headers).unwrap();
        let values: BTreeMap<_, _> = parse_metadata_json(&json).into_iter().collect();
        assert_eq!(values.get("agent").map(String::as_str), Some("codex"));
        assert_eq!(
            values.get("note").map(String::as_str),
            Some("a \\\"quote\\\"")
        );
        assert_eq!(
            values.get(STORED_CACHE_CONTROL).map(String::as_str),
            Some("public, max-age=14400")
        );
        assert_eq!(
            values.get(STORED_EXPIRES).map(String::as_str),
            Some("Sun, 06 Nov 2094 08:49:37 GMT")
        );
        assert_eq!(
            values.get(STORED_CONTENT_ENCODING).map(String::as_str),
            Some("gzip")
        );

        let response = object_headers(
            ServiceResponse::empty(200),
            &ObjectRecord {
                bucket: "bucket".into(),
                key: "key".into(),
                version_id: 1,
                size: 0,
                etag: "etag".into(),
                sha256: vec![7; 32],
                content_type: None,
                meta_json: json,
                created_ms: 0,
            },
            false,
        );
        for (name, value) in [
            ("cache-control", "public, max-age=14400"),
            ("expires", "Sun, 06 Nov 2094 08:49:37 GMT"),
            ("content-encoding", "gzip"),
        ] {
            assert!(
                response
                    .headers
                    .iter()
                    .any(|header| header == &(name.into(), value.into()))
            );
        }
        assert!(
            response
                .headers
                .iter()
                .all(|(name, _)| !name.starts_with("x-amz-meta-@pgs3:"))
        );
    }

    #[test]
    fn create_bucket_region_parses_namespace_document() {
        let body = br#"<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><LocationConstraint>ap-southeast-1</LocationConstraint></CreateBucketConfiguration>"#;
        assert_eq!(parse_create_bucket_region(body).unwrap(), "ap-southeast-1");
    }

    #[test]
    fn get_and_head_checksums_require_enabled_mode_and_a_stored_put_header() {
        let headers = HeaderMap::from_pairs([
            (
                "x-amz-checksum-sha256",
                b"FeKw08M4keuw8e9gnsQZQgwg4yDOlMZfvIwzEkSOsiU=".as_slice(),
            ),
            ("x-amz-checksum-crc64nvme", b"rosUhgp5mIg=".as_slice()),
        ])
        .unwrap();
        let expected = expected_checksums(&headers, &PayloadMode::UnsignedPayload).unwrap();
        let meta_json = put_metadata_json(&headers, &expected).unwrap();
        let info = ObjectRecord {
            bucket: "bucket".into(),
            key: "key".into(),
            version_id: 1,
            size: 16,
            etag: "etag".into(),
            sha256: expected.sha256.clone().unwrap(),
            content_type: None,
            meta_json,
            created_ms: 0,
        };

        let default_response = object_headers(ServiceResponse::empty(200), &info, false);
        assert!(
            default_response
                .headers
                .iter()
                .all(|(name, _)| !name.starts_with("x-amz-checksum-"))
        );

        let enabled_response = object_headers(ServiceResponse::empty(200), &info, true);
        for expected_header in [
            (
                "x-amz-checksum-sha256",
                "FeKw08M4keuw8e9gnsQZQgwg4yDOlMZfvIwzEkSOsiU=",
            ),
            ("x-amz-checksum-crc64nvme", "rosUhgp5mIg="),
        ] {
            assert!(
                enabled_response
                    .headers
                    .iter()
                    .any(|header| header == &(expected_header.0.into(), expected_header.1.into()))
            );
        }
        assert!(
            enabled_response
                .headers
                .iter()
                .all(|(name, _)| { !name.starts_with("x-amz-meta-@pgs3:") })
        );

        for status in [206, 304] {
            let response = object_headers(ServiceResponse::empty(status), &info, true);
            assert!(
                response
                    .headers
                    .iter()
                    .all(|(name, _)| !name.starts_with("x-amz-checksum-"))
            );
        }
    }

    #[test]
    fn direct_put_selection_is_bounded_and_preserves_early_expect_rejection() {
        assert!(direct_put_eligible(Some(0), false, false, false, 64 * 1024));
        assert!(direct_put_eligible(
            Some(64 * 1024),
            false,
            false,
            false,
            64 * 1024
        ));
        assert!(!direct_put_eligible(
            Some(64 * 1024 + 1),
            false,
            false,
            false,
            64 * 1024
        ));
        assert!(!direct_put_eligible(None, false, false, false, 64 * 1024));
        assert!(!direct_put_eligible(Some(1), true, false, false, 64 * 1024));
        assert!(!direct_put_eligible(Some(1), false, true, false, 64 * 1024));
        assert!(!direct_put_eligible(Some(1), false, false, true, 64 * 1024));

        let mut config = ServiceConfig {
            direct_put_bytes: 1024 * 1024,
            ..ServiceConfig::default()
        };
        config.max_control_body_bytes = 1024 * 1024;
        let service = PgS3Service::new(PgDatabase::new(), config);
        assert_eq!(service.config.direct_put_bytes, MAX_DIRECT_PUT_BYTES);
    }

    #[test]
    fn direct_put_body_uses_the_request_cap_snapshot() {
        let mut body = b"first".to_vec();
        append_direct_body(&mut body, b"-second", 12).unwrap();
        assert_eq!(body, b"first-second");
        assert_eq!(
            append_direct_body(&mut body, b"!", 12).unwrap_err().code,
            "EntityTooLarge"
        );
    }

    #[test]
    fn staging_chunk_config_clamps_to_the_registered_guc_range() {
        assert_eq!(
            ServiceConfig::default().staging_chunk_bytes,
            4 * 1024 * 1024
        );

        let below = PgS3Service::new(
            PgDatabase::new(),
            ServiceConfig {
                staging_chunk_bytes: 1,
                ..ServiceConfig::default()
            },
        );
        assert_eq!(below.config.staging_chunk_bytes, MIN_STAGING_CHUNK_BYTES);

        let above = PgS3Service::new(
            PgDatabase::new(),
            ServiceConfig {
                staging_chunk_bytes: usize::MAX,
                ..ServiceConfig::default()
            },
        );
        assert_eq!(above.config.staging_chunk_bytes, MAX_STAGING_CHUNK_BYTES);
    }

    #[test]
    fn staged_body_uses_the_request_chunk_snapshot_after_service_reload() {
        let request_chunk_bytes = 256 * 1024;
        let rebuilt = PgS3Service::new(
            PgDatabase::new(),
            ServiceConfig {
                staging_chunk_bytes: 64 * 1024,
                ..ServiceConfig::default()
            },
        );
        let mut sink = BodySink::Staged {
            bucket: "bucket".into(),
            key: "key".into(),
            upload_id: "00000000-0000-0000-0000-000000000000".into(),
            part_number: 0,
            sequence: 0,
            staging_chunk_bytes: request_chunk_bytes,
            buffer: Vec::with_capacity(request_chunk_bytes),
            chunk_blob_ids: Vec::new(),
            chunk_sizes: Vec::new(),
        };

        let BodySink::Staged {
            staging_chunk_bytes,
            buffer,
            ..
        } = &mut sink
        else {
            unreachable!();
        };
        let first = vec![1_u8; rebuilt.config.staging_chunk_bytes];
        let mut first = first.as_slice();
        assert!(!append_staged_slice(
            buffer,
            &mut first,
            *staging_chunk_bytes
        ));
        assert!(first.is_empty());
        assert_eq!(buffer.len(), rebuilt.config.staging_chunk_bytes);

        let rest = vec![2_u8; request_chunk_bytes - buffer.len()];
        let mut rest = rest.as_slice();
        assert!(append_staged_slice(buffer, &mut rest, *staging_chunk_bytes));
        assert!(rest.is_empty());
        assert_eq!(buffer.len(), request_chunk_bytes);
    }

    #[test]
    fn unconditional_get_fast_path_excludes_every_semantic_header() {
        assert!(unconditional_get_fast_path(&HeaderMap::default(), false));
        assert!(!unconditional_get_fast_path(&HeaderMap::default(), true));
        for name in [
            "if-match",
            "if-none-match",
            "if-modified-since",
            "if-unmodified-since",
            "range",
            "if-range",
            "x-amz-checksum-mode",
        ] {
            let headers = HeaderMap::from_pairs([(name, b"value".as_slice())]).unwrap();
            assert!(!unconditional_get_fast_path(&headers, false), "{name}");
        }
    }

    #[test]
    fn checksum_mode_and_current_delete_marker_head_are_strictly_gated() {
        assert!(!checksum_mode_enabled(&HeaderMap::default()).unwrap());
        let enabled =
            HeaderMap::from_pairs([("x-amz-checksum-mode", b"ENABLED".as_slice())]).unwrap();
        assert!(checksum_mode_enabled(&enabled).unwrap());
        let invalid =
            HeaderMap::from_pairs([("x-amz-checksum-mode", b"DISABLED".as_slice())]).unwrap();
        assert_eq!(
            checksum_mode_enabled(&invalid).unwrap_err().code,
            "InvalidArgument"
        );

        let no_key = S3Error::new(404, "NoSuchKey", "missing");
        assert!(should_probe_current_delete_marker(true, None, &no_key));
        assert!(!should_probe_current_delete_marker(false, None, &no_key));
        assert!(!should_probe_current_delete_marker(true, Some(7), &no_key));
        assert!(!should_probe_current_delete_marker(
            true,
            None,
            &S3Error::new(404, "NoSuchBucket", "hidden")
        ));

        let response = delete_marker_head_response(&DeleteMarkerRecord { version_id: 42 });
        assert_eq!(response.status, 404);
        assert!(
            response
                .headers
                .contains(&("x-amz-delete-marker".into(), "true".into()))
        );
        assert!(
            response
                .headers
                .contains(&("x-amz-version-id".into(), "42".into()))
        );
    }

    #[test]
    fn self_copy_requires_replacement_metadata() {
        let error = validate_copy_destination("bucket", "key", "bucket", "key", false)
            .expect_err("an unchanged self-copy must be rejected");
        assert_eq!((error.status, error.code), (400, "InvalidRequest"));
        validate_copy_destination("bucket", "key", "bucket", "key", true).unwrap();
        validate_copy_destination("bucket", "key", "bucket", "other", false).unwrap();
    }

    #[test]
    fn database_errors_map_only_from_sqlstate_and_detail() {
        let cases = [
            ("42501", None, 403, "AccessDenied"),
            ("25006", None, 503, "ServiceUnavailable"),
            ("57014", None, 503, "SlowDown"),
            ("0A000", None, 501, "NotImplemented"),
            ("P3B01", None, 404, "NoSuchBucket"),
            ("P3U01", None, 404, "NoSuchUpload"),
            ("P3K01", None, 404, "NoSuchKey"),
            (
                "P3K01",
                Some("context pgs3.error=NoSuchVersion"),
                404,
                "NoSuchVersion",
            ),
            ("P3E01", None, 409, "BucketAlreadyExists"),
            ("P3F01", None, 409, "BucketNotEmpty"),
            ("P3C01", None, 412, "PreconditionFailed"),
            ("P3N01", None, 304, "NotModified"),
            ("P3H01", None, 400, "BadDigest"),
            ("P3P01", None, 400, "InvalidPart"),
            (
                "P3P01",
                Some("pgs3.error=InvalidPartOrder"),
                400,
                "InvalidPartOrder",
            ),
            (
                "P3P01",
                Some("pgs3.error=EntityTooSmall"),
                400,
                "EntityTooSmall",
            ),
            ("P3R01", None, 416, "InvalidRange"),
            ("P3S01", None, 400, "EntityTooLarge"),
            (
                "XX000",
                Some("pgs3.error=NoSuchBucket"),
                404,
                "NoSuchBucket",
            ),
            (
                "XX000",
                Some("pgs3.error=NoSuchUpload"),
                404,
                "NoSuchUpload",
            ),
            (
                "XX000",
                Some("pgs3.error=InvalidPartOrder"),
                400,
                "InvalidPartOrder",
            ),
            (
                "22023",
                Some("pgs3.error=InvalidBucketName"),
                400,
                "InvalidBucketName",
            ),
            ("22023", None, 400, "InvalidArgument"),
            ("22P02", None, 400, "InvalidArgument"),
            ("XX001", None, 500, "InternalError"),
        ];

        for (state, detail, status, code) in cases {
            for changed_message in [
                "localized or rewritten message",
                "NoSuchBucket InvalidPart permission denied checksum read-only",
            ] {
                let mapped = map_database_error(Some(state), detail, changed_message);
                assert_eq!((mapped.status, mapped.code), (status, code), "{state}");
            }
        }
        let mapped = map_database_error(None, None, "NoSuchBucket permission denied");
        assert_eq!((mapped.status, mapped.code), (500, "InternalError"));
    }

    #[test]
    fn delete_objects_fields_distinguish_data_markers_and_missing_repeats() {
        let versioned = DeleteTarget {
            key: "key".into(),
            version_id: Some(7),
        };
        let data = super::super::db::DeleteRecord {
            key: "key".into(),
            version_id: 7,
            delete_marker: false,
            deleted: true,
        };
        assert_eq!(
            deleted_response_fields(&versioned, &data),
            (Some("7".into()), false, None)
        );

        let marker = super::super::db::DeleteRecord {
            delete_marker: true,
            ..data.clone()
        };
        assert_eq!(
            deleted_response_fields(&versioned, &marker),
            (Some("7".into()), true, Some("7".into()))
        );

        // A repeated request for the now-missing marker is still a successful
        // Deleted entry, but cannot claim that this invocation deleted one.
        let missing_repeat = super::super::db::DeleteRecord {
            deleted: false,
            ..data.clone()
        };
        assert_eq!(
            deleted_response_fields(&versioned, &missing_repeat),
            (Some("7".into()), false, None)
        );

        let unversioned = DeleteTarget {
            key: "key".into(),
            version_id: None,
        };
        let created_marker = super::super::db::DeleteRecord {
            key: "key".into(),
            version_id: 9,
            delete_marker: true,
            deleted: true,
        };
        assert_eq!(
            deleted_response_fields(&unversioned, &created_marker),
            (None, true, Some("9".into()))
        );
    }
}
