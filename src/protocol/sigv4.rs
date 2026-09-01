//! AWS Signature Version 4 canonicalization and verification for S3.

use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

use super::http::{HeaderMap, HttpParseError, QueryParams, RequestHead, percent_decode};

const ALGORITHM: &str = "AWS4-HMAC-SHA256";
const TERMINATOR: &str = "aws4_request";
#[cfg(test)]
const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
pub const MAX_PRESIGN_EXPIRY_SECONDS: u64 = 7 * 24 * 60 * 60;

type HmacSha256 = Hmac<Sha256>;

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum PayloadMode {
    FullHash([u8; 32]),
    UnsignedPayload,
    StreamingSigned,
    StreamingUnsignedTrailer,
}

impl PayloadMode {
    pub fn parse(value: &str) -> Result<Self, SigV4Error> {
        match value {
            "UNSIGNED-PAYLOAD" => Ok(Self::UnsignedPayload),
            "STREAMING-AWS4-HMAC-SHA256-PAYLOAD" => Ok(Self::StreamingSigned),
            "STREAMING-UNSIGNED-PAYLOAD-TRAILER" => Ok(Self::StreamingUnsignedTrailer),
            value if value.len() == 64 => Ok(Self::FullHash(decode_hex_32(value.as_bytes())?)),
            _ => Err(SigV4Error::UnsupportedPayloadMode),
        }
    }

    /// Validates a non-streaming request body. Streaming modes must instead be
    /// passed through `protocol::chunked::AwsChunkedDecoder`.
    #[allow(dead_code)]
    pub fn verify_body(&self, body: &[u8]) -> Result<(), SigV4Error> {
        match self {
            Self::FullHash(expected) => {
                let actual: [u8; 32] = Sha256::digest(body).into();
                if constant_time_eq(expected, &actual) {
                    Ok(())
                } else {
                    Err(SigV4Error::PayloadHashMismatch)
                }
            }
            Self::UnsignedPayload => Ok(()),
            Self::StreamingSigned | Self::StreamingUnsignedTrailer => {
                Err(SigV4Error::StreamingPayloadRequiresDecoder)
            }
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CredentialScope {
    pub access_key: String,
    pub date: String,
    pub region: String,
    pub service: String,
}

impl CredentialScope {
    #[must_use]
    pub fn scope(&self) -> String {
        format!(
            "{}/{}/{}/{}",
            self.date, self.region, self.service, TERMINATOR
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct HeaderAuthorization {
    pub credential: CredentialScope,
    pub signed_headers: Vec<String>,
    pub signature: [u8; 32],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PresignedAuthorization {
    pub credential: CredentialScope,
    pub signed_headers: Vec<String>,
    pub signature: [u8; 32],
    pub amz_date: String,
    pub expires_seconds: u64,
}

pub struct SigV4Request<'a> {
    pub method: &'a str,
    pub raw_path: &'a str,
    pub raw_query: Option<&'a str>,
    pub query: &'a QueryParams,
    pub headers: &'a HeaderMap,
}

impl<'a> From<&'a RequestHead> for SigV4Request<'a> {
    fn from(request: &'a RequestHead) -> Self {
        Self {
            method: &request.method,
            raw_path: &request.target.raw_path,
            raw_query: request.target.raw_query.as_deref(),
            query: &request.target.query,
            headers: &request.headers,
        }
    }
}

#[derive(Clone, Debug)]
pub struct VerificationConfig {
    pub now: SystemTime,
    pub max_clock_skew: Duration,
    pub expected_region: Option<String>,
    pub expected_service: String,
}

impl Default for VerificationConfig {
    fn default() -> Self {
        Self {
            now: SystemTime::now(),
            max_clock_skew: Duration::from_secs(15 * 60),
            expected_region: None,
            expected_service: "s3".to_owned(),
        }
    }
}

#[derive(Clone)]
pub struct StreamingSigningContext {
    pub signing_key: [u8; 32],
    pub amz_date: String,
    pub credential_scope: String,
    pub seed_signature: [u8; 32],
}

impl fmt::Debug for StreamingSigningContext {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StreamingSigningContext")
            .field("signing_key", &"[REDACTED]")
            .field("amz_date", &self.amz_date)
            .field("credential_scope", &self.credential_scope)
            .field("seed_signature", &hex_lower(&self.seed_signature))
            .finish()
    }
}

#[derive(Clone, Debug)]
pub struct VerifiedSignature {
    #[allow(dead_code)]
    pub credential: CredentialScope,
    #[allow(dead_code)]
    pub signed_headers: Vec<String>,
    pub payload_mode: PayloadMode,
    pub security_token: Option<String>,
    #[allow(dead_code)]
    pub canonical_request_hash: [u8; 32],
    pub streaming_context: Option<StreamingSigningContext>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum SigV4Error {
    MissingHeader(&'static str),
    DuplicateHeader(&'static str),
    MissingQueryParameter(&'static str),
    DuplicateQueryParameter(&'static str),
    InvalidUtf8,
    InvalidAuthorization,
    UnsupportedAlgorithm,
    InvalidCredentialScope,
    InvalidSignedHeaders,
    MissingSignedHeader(String),
    UnsignedAmzHeader(String),
    MissingPayloadHash,
    UnsupportedPayloadMode,
    InvalidHex,
    InvalidTimestamp,
    RequestTimeTooSkewed,
    PresignedUrlNotYetValid,
    PresignedUrlExpired,
    InvalidExpires,
    RegionMismatch,
    ServiceMismatch,
    SignatureMismatch,
    #[allow(dead_code)]
    PayloadHashMismatch,
    #[allow(dead_code)]
    StreamingPayloadRequiresDecoder,
    InvalidCanonicalUri,
    InvalidCanonicalQuery,
}

impl fmt::Display for SigV4Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingHeader(name) => write!(f, "missing SigV4 header {name}"),
            Self::DuplicateHeader(name) => write!(f, "duplicate SigV4 header {name}"),
            Self::MissingQueryParameter(name) => write!(f, "missing SigV4 query parameter {name}"),
            Self::DuplicateQueryParameter(name) => {
                write!(f, "duplicate SigV4 query parameter {name}")
            }
            Self::InvalidUtf8 => f.write_str("SigV4 field is not UTF-8"),
            Self::InvalidAuthorization => f.write_str("invalid SigV4 Authorization value"),
            Self::UnsupportedAlgorithm => f.write_str("unsupported AWS signing algorithm"),
            Self::InvalidCredentialScope => f.write_str("invalid SigV4 credential scope"),
            Self::InvalidSignedHeaders => f.write_str("invalid SigV4 SignedHeaders list"),
            Self::MissingSignedHeader(name) => write!(f, "signed header is missing: {name}"),
            Self::UnsignedAmzHeader(name) => write!(f, "x-amz header was not signed: {name}"),
            Self::MissingPayloadHash => f.write_str("missing x-amz-content-sha256"),
            Self::UnsupportedPayloadMode => f.write_str("unsupported x-amz-content-sha256 mode"),
            Self::InvalidHex => f.write_str("invalid hexadecimal SigV4 value"),
            Self::InvalidTimestamp => f.write_str("invalid SigV4 timestamp"),
            Self::RequestTimeTooSkewed => {
                f.write_str("request timestamp is outside the allowed skew")
            }
            Self::PresignedUrlNotYetValid => f.write_str("presigned URL is not valid yet"),
            Self::PresignedUrlExpired => f.write_str("presigned URL has expired"),
            Self::InvalidExpires => f.write_str("X-Amz-Expires must be 1..604800 seconds"),
            Self::RegionMismatch => {
                f.write_str("credential scope region does not match this endpoint")
            }
            Self::ServiceMismatch => f.write_str("credential scope service is not s3"),
            Self::SignatureMismatch => f.write_str("SigV4 signature does not match"),
            Self::PayloadHashMismatch => f.write_str("request payload SHA-256 does not match"),
            Self::StreamingPayloadRequiresDecoder => {
                f.write_str("streaming payload must be verified by the aws-chunked decoder")
            }
            Self::InvalidCanonicalUri => {
                f.write_str("request path cannot be canonicalized for SigV4")
            }
            Self::InvalidCanonicalQuery => {
                f.write_str("request query cannot be canonicalized for SigV4")
            }
        }
    }
}

impl std::error::Error for SigV4Error {}

pub fn parse_header_authorization(headers: &HeaderMap) -> Result<HeaderAuthorization, SigV4Error> {
    let authorization =
        one_header(headers, "authorization")?.ok_or(SigV4Error::MissingHeader("Authorization"))?;
    let authorization = std::str::from_utf8(authorization).map_err(|_| SigV4Error::InvalidUtf8)?;
    let (algorithm, attributes) = authorization
        .split_once(' ')
        .ok_or(SigV4Error::InvalidAuthorization)?;
    if algorithm != ALGORITHM {
        return Err(SigV4Error::UnsupportedAlgorithm);
    }

    let mut credential = None;
    let mut signed_headers = None;
    let mut signature = None;
    for attribute in attributes.split(',') {
        let (name, value) = attribute
            .trim()
            .split_once('=')
            .ok_or(SigV4Error::InvalidAuthorization)?;
        if value.is_empty() {
            return Err(SigV4Error::InvalidAuthorization);
        }
        match name {
            "Credential" if credential.is_none() => credential = Some(parse_credential(value)?),
            "SignedHeaders" if signed_headers.is_none() => {
                signed_headers = Some(parse_signed_headers(value)?)
            }
            "Signature" if signature.is_none() => {
                signature = Some(decode_hex_32(value.as_bytes())?)
            }
            _ => return Err(SigV4Error::InvalidAuthorization),
        }
    }
    Ok(HeaderAuthorization {
        credential: credential.ok_or(SigV4Error::InvalidAuthorization)?,
        signed_headers: signed_headers.ok_or(SigV4Error::InvalidAuthorization)?,
        signature: signature.ok_or(SigV4Error::InvalidAuthorization)?,
    })
}

pub fn parse_presigned_authorization(
    query: &QueryParams,
) -> Result<PresignedAuthorization, SigV4Error> {
    let algorithm = query_one_str(query, "X-Amz-Algorithm")?;
    if algorithm != ALGORITHM {
        return Err(SigV4Error::UnsupportedAlgorithm);
    }
    let expires_seconds = query_one_str(query, "X-Amz-Expires")?
        .parse::<u64>()
        .map_err(|_| SigV4Error::InvalidExpires)?;
    if !(1..=MAX_PRESIGN_EXPIRY_SECONDS).contains(&expires_seconds) {
        return Err(SigV4Error::InvalidExpires);
    }
    Ok(PresignedAuthorization {
        credential: parse_credential(query_one_str(query, "X-Amz-Credential")?)?,
        signed_headers: parse_signed_headers(query_one_str(query, "X-Amz-SignedHeaders")?)?,
        signature: decode_hex_32(query_one(query, "X-Amz-Signature")?)?,
        amz_date: query_one_str(query, "X-Amz-Date")?.to_owned(),
        expires_seconds,
    })
}

/// Verifies an Authorization-header signature with a caller-supplied secret.
/// Parse the authorization first to select the credential without exposing a
/// PostgreSQL dependency to this module.
pub fn verify_header(
    request: &SigV4Request<'_>,
    secret_access_key: &[u8],
    config: &VerificationConfig,
) -> Result<VerifiedSignature, SigV4Error> {
    let authorization = parse_header_authorization(request.headers)?;
    validate_scope(&authorization.credential, config)?;
    validate_signed_headers(request.headers, &authorization.signed_headers)?;

    let amz_date = one_header(request.headers, "x-amz-date")?
        .ok_or(SigV4Error::MissingHeader("x-amz-date"))?;
    let amz_date = std::str::from_utf8(amz_date).map_err(|_| SigV4Error::InvalidUtf8)?;
    let signed_time = parse_amz_timestamp(amz_date)?;
    if authorization.credential.date != amz_date[..8] {
        return Err(SigV4Error::InvalidCredentialScope);
    }
    validate_header_time(signed_time, config)?;

    let payload_literal = one_header(request.headers, "x-amz-content-sha256")?
        .ok_or(SigV4Error::MissingPayloadHash)?;
    let payload_literal =
        std::str::from_utf8(payload_literal).map_err(|_| SigV4Error::InvalidUtf8)?;
    let payload_mode = PayloadMode::parse(payload_literal)?;

    let canonical_request = build_canonical_request(
        request,
        &authorization.signed_headers,
        payload_literal,
        false,
    )?;
    let canonical_request_hash: [u8; 32] = Sha256::digest(&canonical_request).into();
    let credential_scope = authorization.credential.scope();
    let string_to_sign = string_to_sign(amz_date, &credential_scope, &canonical_request_hash);
    let signing_key = derive_signing_key(secret_access_key, &authorization.credential);
    verify_hmac(
        &signing_key,
        string_to_sign.as_bytes(),
        &authorization.signature,
    )?;

    let security_token = one_header(request.headers, "x-amz-security-token")?
        .map(|value| std::str::from_utf8(value).map(str::to_owned))
        .transpose()
        .map_err(|_| SigV4Error::InvalidUtf8)?;
    let streaming_context =
        matches!(payload_mode, PayloadMode::StreamingSigned).then(|| StreamingSigningContext {
            signing_key,
            amz_date: amz_date.to_owned(),
            credential_scope,
            seed_signature: authorization.signature,
        });
    Ok(VerifiedSignature {
        credential: authorization.credential,
        signed_headers: authorization.signed_headers,
        payload_mode,
        security_token,
        canonical_request_hash,
        streaming_context,
    })
}

/// Verifies an S3 query-parameter (presigned URL) signature.
pub fn verify_presigned(
    request: &SigV4Request<'_>,
    secret_access_key: &[u8],
    config: &VerificationConfig,
) -> Result<VerifiedSignature, SigV4Error> {
    let authorization = parse_presigned_authorization(request.query)?;
    validate_scope(&authorization.credential, config)?;
    validate_signed_headers(request.headers, &authorization.signed_headers)?;
    let signed_time = parse_amz_timestamp(&authorization.amz_date)?;
    if authorization.credential.date != authorization.amz_date[..8] {
        return Err(SigV4Error::InvalidCredentialScope);
    }
    validate_presign_time(signed_time, authorization.expires_seconds, config)?;

    let canonical_request = build_canonical_request(
        request,
        &authorization.signed_headers,
        "UNSIGNED-PAYLOAD",
        true,
    )?;
    let canonical_request_hash: [u8; 32] = Sha256::digest(&canonical_request).into();
    let credential_scope = authorization.credential.scope();
    let string_to_sign = string_to_sign(
        &authorization.amz_date,
        &credential_scope,
        &canonical_request_hash,
    );
    let signing_key = derive_signing_key(secret_access_key, &authorization.credential);
    verify_hmac(
        &signing_key,
        string_to_sign.as_bytes(),
        &authorization.signature,
    )?;

    let security_token = query_optional_one(request.query, "X-Amz-Security-Token")?
        .map(|value| std::str::from_utf8(value).map(str::to_owned))
        .transpose()
        .map_err(|_| SigV4Error::InvalidUtf8)?;
    Ok(VerifiedSignature {
        credential: authorization.credential,
        signed_headers: authorization.signed_headers,
        payload_mode: PayloadMode::UnsignedPayload,
        security_token,
        canonical_request_hash,
        streaming_context: None,
    })
}

/// S3 does not normalize `.`/`..` path segments. Existing percent escapes are
/// preserved (with uppercase hex) while raw non-unreserved bytes are encoded.
pub fn canonical_uri(raw_path: &str) -> Result<String, SigV4Error> {
    if !raw_path.starts_with('/') {
        return Err(SigV4Error::InvalidCanonicalUri);
    }
    let input = raw_path.as_bytes();
    let mut output = String::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        let byte = input[index];
        if byte == b'/' || is_unreserved(byte) {
            output.push(char::from(byte));
            index += 1;
        } else if byte == b'%' {
            if index + 2 >= input.len()
                || hex_nibble(input[index + 1]).is_none()
                || hex_nibble(input[index + 2]).is_none()
            {
                return Err(SigV4Error::InvalidCanonicalUri);
            }
            output.push('%');
            output.push(char::from(input[index + 1].to_ascii_uppercase()));
            output.push(char::from(input[index + 2].to_ascii_uppercase()));
            index += 3;
        } else {
            push_percent_encoded(&mut output, byte);
            index += 1;
        }
    }
    Ok(output)
}

/// Canonicalizes query pairs after percent-decoding, sorts encoded names then
/// values, and optionally excludes `X-Amz-Signature` for presigned URLs.
pub fn canonical_query(
    raw_query: Option<&str>,
    exclude_signature: bool,
) -> Result<String, SigV4Error> {
    let Some(raw_query) = raw_query else {
        return Ok(String::new());
    };
    if raw_query.is_empty() {
        return Ok(String::new());
    }
    let mut pairs = Vec::new();
    for component in raw_query.split('&') {
        let (raw_name, raw_value) = component.split_once('=').unwrap_or((component, ""));
        let name = percent_decode(raw_name.as_bytes()).map_err(map_canonical_query_error)?;
        if exclude_signature && name == b"X-Amz-Signature" {
            continue;
        }
        let value = percent_decode(raw_value.as_bytes()).map_err(map_canonical_query_error)?;
        pairs.push((aws_encode(&name, true), aws_encode(&value, true)));
    }
    pairs.sort_unstable();
    Ok(pairs
        .into_iter()
        .map(|(name, value)| format!("{name}={value}"))
        .collect::<Vec<_>>()
        .join("&"))
}

/// Builds canonical headers in signed-header order. Duplicate field values are
/// normalized independently then joined with commas, as AWS specifies.
pub fn canonical_headers(
    headers: &HeaderMap,
    signed_headers: &[String],
) -> Result<Vec<u8>, SigV4Error> {
    let mut canonical = Vec::new();
    for name in signed_headers {
        let values: Vec<_> = headers.get_all(name).collect();
        if values.is_empty() {
            return Err(SigV4Error::MissingSignedHeader(name.clone()));
        }
        canonical.extend_from_slice(name.as_bytes());
        canonical.push(b':');
        for (index, value) in values.iter().enumerate() {
            if index != 0 {
                canonical.push(b',');
            }
            canonical.extend_from_slice(&normalize_header_value(value));
        }
        canonical.push(b'\n');
    }
    Ok(canonical)
}

fn build_canonical_request(
    request: &SigV4Request<'_>,
    signed_headers: &[String],
    payload_literal: &str,
    exclude_signature: bool,
) -> Result<Vec<u8>, SigV4Error> {
    let uri = canonical_uri(request.raw_path)?;
    let query = canonical_query(request.raw_query, exclude_signature)?;
    let headers = canonical_headers(request.headers, signed_headers)?;
    let signed = signed_headers.join(";");
    let mut canonical = Vec::new();
    canonical.extend_from_slice(request.method.as_bytes());
    canonical.push(b'\n');
    canonical.extend_from_slice(uri.as_bytes());
    canonical.push(b'\n');
    canonical.extend_from_slice(query.as_bytes());
    canonical.push(b'\n');
    canonical.extend_from_slice(&headers);
    // CanonicalHeaders itself ends in LF, and the canonical-request field
    // separator contributes a second LF before SignedHeaders.
    canonical.push(b'\n');
    canonical.extend_from_slice(signed.as_bytes());
    canonical.push(b'\n');
    canonical.extend_from_slice(payload_literal.as_bytes());
    Ok(canonical)
}

fn validate_signed_headers(headers: &HeaderMap, signed: &[String]) -> Result<(), SigV4Error> {
    if !signed.iter().any(|name| name == "host") {
        return Err(SigV4Error::InvalidSignedHeaders);
    }
    for name in signed {
        if headers.get(name).is_none() {
            return Err(SigV4Error::MissingSignedHeader(name.clone()));
        }
    }
    for field in headers.fields() {
        if field.name.starts_with("x-amz-")
            && field.name != "x-amz-content-sha256"
            && !signed.iter().any(|name| name == &field.name)
        {
            return Err(SigV4Error::UnsignedAmzHeader(field.name.clone()));
        }
    }
    Ok(())
}

fn parse_credential(value: &str) -> Result<CredentialScope, SigV4Error> {
    let fields: Vec<_> = value.split('/').collect();
    if fields.len() != 5
        || fields.iter().any(|field| field.is_empty())
        || fields[4] != TERMINATOR
        || fields[1].len() != 8
        || !fields[1].bytes().all(|byte| byte.is_ascii_digit())
    {
        return Err(SigV4Error::InvalidCredentialScope);
    }
    Ok(CredentialScope {
        access_key: fields[0].to_owned(),
        date: fields[1].to_owned(),
        region: fields[2].to_owned(),
        service: fields[3].to_owned(),
    })
}

fn parse_signed_headers(value: &str) -> Result<Vec<String>, SigV4Error> {
    let headers: Vec<_> = value.split(';').map(str::to_owned).collect();
    if headers.is_empty()
        || headers
            .iter()
            .any(|name| name.is_empty() || !name.bytes().all(is_lowercase_header_token))
        || headers.windows(2).any(|pair| pair[0] >= pair[1])
    {
        return Err(SigV4Error::InvalidSignedHeaders);
    }
    Ok(headers)
}

fn is_lowercase_header_token(byte: u8) -> bool {
    byte.is_ascii_lowercase()
        || byte.is_ascii_digit()
        || matches!(
            byte,
            b'!' | b'#'
                | b'$'
                | b'%'
                | b'&'
                | b'\''
                | b'*'
                | b'+'
                | b'-'
                | b'.'
                | b'^'
                | b'_'
                | b'`'
                | b'|'
                | b'~'
        )
}

fn validate_scope(
    credential: &CredentialScope,
    config: &VerificationConfig,
) -> Result<(), SigV4Error> {
    if credential.service != config.expected_service {
        return Err(SigV4Error::ServiceMismatch);
    }
    if config
        .expected_region
        .as_ref()
        .is_some_and(|region| region != &credential.region)
    {
        return Err(SigV4Error::RegionMismatch);
    }
    Ok(())
}

fn validate_header_time(timestamp: i64, config: &VerificationConfig) -> Result<(), SigV4Error> {
    let now = unix_seconds(config.now)?;
    if now.abs_diff(timestamp) > config.max_clock_skew.as_secs() {
        return Err(SigV4Error::RequestTimeTooSkewed);
    }
    Ok(())
}

fn validate_presign_time(
    timestamp: i64,
    expires: u64,
    config: &VerificationConfig,
) -> Result<(), SigV4Error> {
    let now = unix_seconds(config.now)?;
    let skew = i64::try_from(config.max_clock_skew.as_secs()).unwrap_or(i64::MAX);
    if now < timestamp.saturating_sub(skew) {
        return Err(SigV4Error::PresignedUrlNotYetValid);
    }
    let expires = i64::try_from(expires).map_err(|_| SigV4Error::InvalidExpires)?;
    if now > timestamp.saturating_add(expires) {
        return Err(SigV4Error::PresignedUrlExpired);
    }
    Ok(())
}

fn parse_amz_timestamp(value: &str) -> Result<i64, SigV4Error> {
    let bytes = value.as_bytes();
    if bytes.len() != 16 || bytes[8] != b'T' || bytes[15] != b'Z' {
        return Err(SigV4Error::InvalidTimestamp);
    }
    for (index, byte) in bytes.iter().enumerate() {
        if index != 8 && index != 15 && !byte.is_ascii_digit() {
            return Err(SigV4Error::InvalidTimestamp);
        }
    }
    let year = decimal(&bytes[0..4])?;
    let month = decimal(&bytes[4..6])?;
    let day = decimal(&bytes[6..8])?;
    let hour = decimal(&bytes[9..11])?;
    let minute = decimal(&bytes[11..13])?;
    let second = decimal(&bytes[13..15])?;
    if year < 1970
        || !(1..=12).contains(&month)
        || day == 0
        || day > days_in_month(year, month)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return Err(SigV4Error::InvalidTimestamp);
    }
    let days = days_from_civil(year, month, day);
    days.checked_mul(86_400)
        .and_then(|seconds| seconds.checked_add(i64::from(hour * 3600 + minute * 60 + second)))
        .ok_or(SigV4Error::InvalidTimestamp)
}

fn days_from_civil(year: u32, month: u32, day: u32) -> i64 {
    // Howard Hinnant's proleptic Gregorian conversion, offset to Unix epoch.
    let mut year = i64::from(year);
    let month = i64::from(month);
    let day = i64::from(day);
    year -= i64::from(month <= 2);
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let shifted_month = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * shifted_month + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn days_in_month(year: u32, month: u32) -> u32 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year.is_multiple_of(400) || year.is_multiple_of(4) && !year.is_multiple_of(100) => 29,
        2 => 28,
        _ => 0,
    }
}

fn decimal(bytes: &[u8]) -> Result<u32, SigV4Error> {
    let mut value = 0_u32;
    for byte in bytes {
        value = value * 10 + u32::from(byte - b'0');
    }
    Ok(value)
}

fn unix_seconds(time: SystemTime) -> Result<i64, SigV4Error> {
    let seconds = time
        .duration_since(UNIX_EPOCH)
        .map_err(|_| SigV4Error::InvalidTimestamp)?
        .as_secs();
    i64::try_from(seconds).map_err(|_| SigV4Error::InvalidTimestamp)
}

fn string_to_sign(amz_date: &str, scope: &str, canonical_hash: &[u8; 32]) -> String {
    format!(
        "{ALGORITHM}\n{amz_date}\n{scope}\n{}",
        hex_lower(canonical_hash)
    )
}

pub(crate) fn derive_signing_key(secret: &[u8], credential: &CredentialScope) -> [u8; 32] {
    let mut initial = Vec::with_capacity(secret.len() + 4);
    initial.extend_from_slice(b"AWS4");
    initial.extend_from_slice(secret);
    let date_key = hmac_bytes(&initial, credential.date.as_bytes());
    let region_key = hmac_bytes(&date_key, credential.region.as_bytes());
    let service_key = hmac_bytes(&region_key, credential.service.as_bytes());
    hmac_bytes(&service_key, TERMINATOR.as_bytes())
}

pub(crate) fn hmac_bytes(key: &[u8], value: &[u8]) -> [u8; 32] {
    let mut hmac = HmacSha256::new_from_slice(key).expect("HMAC accepts every key length");
    hmac.update(value);
    hmac.finalize().into_bytes().into()
}

pub(crate) fn verify_hmac(
    key: &[u8],
    value: &[u8],
    signature: &[u8; 32],
) -> Result<(), SigV4Error> {
    let mut hmac = HmacSha256::new_from_slice(key).expect("HMAC accepts every key length");
    hmac.update(value);
    // `verify_slice` uses the `subtle` crate's constant-time comparison.
    hmac.verify_slice(signature)
        .map_err(|_| SigV4Error::SignatureMismatch)
}

fn one_header<'a>(
    headers: &'a HeaderMap,
    name: &'static str,
) -> Result<Option<&'a [u8]>, SigV4Error> {
    let mut values = headers.get_all(name);
    let value = values.next();
    if values.next().is_some() {
        return Err(SigV4Error::DuplicateHeader(name));
    }
    Ok(value)
}

fn query_one<'a>(query: &'a QueryParams, name: &'static str) -> Result<&'a [u8], SigV4Error> {
    query_optional_one(query, name)?.ok_or(SigV4Error::MissingQueryParameter(name))
}

fn query_optional_one<'a>(
    query: &'a QueryParams,
    name: &'static str,
) -> Result<Option<&'a [u8]>, SigV4Error> {
    let mut values = query.get_all(name);
    let value = values.next();
    if values.next().is_some() {
        return Err(SigV4Error::DuplicateQueryParameter(name));
    }
    Ok(value)
}

fn query_one_str<'a>(query: &'a QueryParams, name: &'static str) -> Result<&'a str, SigV4Error> {
    std::str::from_utf8(query_one(query, name)?).map_err(|_| SigV4Error::InvalidUtf8)
}

fn normalize_header_value(value: &[u8]) -> Vec<u8> {
    let mut normalized = Vec::with_capacity(value.len());
    let mut in_whitespace = true;
    for byte in value {
        if matches!(byte, b' ' | b'\t') {
            if !in_whitespace {
                normalized.push(b' ');
                in_whitespace = true;
            }
        } else {
            normalized.push(*byte);
            in_whitespace = false;
        }
    }
    if normalized.last() == Some(&b' ') {
        normalized.pop();
    }
    normalized
}

fn aws_encode(value: &[u8], encode_slash: bool) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value {
        if is_unreserved(*byte) || *byte == b'/' && !encode_slash {
            encoded.push(char::from(*byte));
        } else {
            push_percent_encoded(&mut encoded, *byte);
        }
    }
    encoded
}

fn is_unreserved(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~')
}

fn push_percent_encoded(output: &mut String, byte: u8) {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    output.push('%');
    output.push(char::from(HEX[usize::from(byte >> 4)]));
    output.push(char::from(HEX[usize::from(byte & 0x0f)]));
}

fn decode_hex_32(value: &[u8]) -> Result<[u8; 32], SigV4Error> {
    if value.len() != 64 {
        return Err(SigV4Error::InvalidHex);
    }
    let mut output = [0_u8; 32];
    for (index, pair) in value.as_chunks::<2>().0.iter().enumerate() {
        let high = hex_nibble(pair[0]).ok_or(SigV4Error::InvalidHex)?;
        let low = hex_nibble(pair[1]).ok_or(SigV4Error::InvalidHex)?;
        output[index] = high << 4 | low;
    }
    Ok(output)
}

pub(crate) fn hex_lower(value: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(value.len() * 2);
    for byte in value {
        output.push(char::from(HEX[usize::from(byte >> 4)]));
        output.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    output
}

pub(crate) fn decode_signature_hex(value: &[u8]) -> Result<[u8; 32], SigV4Error> {
    decode_hex_32(value)
}

pub(crate) fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn map_canonical_query_error(error: HttpParseError) -> SigV4Error {
    match error {
        HttpParseError::InvalidPercentEncoding => SigV4Error::InvalidCanonicalQuery,
        _ => SigV4Error::InvalidCanonicalQuery,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ACCESS: &str = "AKIAIOSFODNN7EXAMPLE";
    const SECRET: &[u8] = b"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";

    fn at(timestamp: &str) -> SystemTime {
        UNIX_EPOCH + Duration::from_secs(parse_amz_timestamp(timestamp).unwrap() as u64)
    }

    #[test]
    fn verifies_official_aws_s3_header_example() {
        let headers = HeaderMap::from_pairs([
            ("Host", "examplebucket.s3.amazonaws.com"),
            ("Range", "bytes=0-9"),
            ("x-amz-content-sha256", EMPTY_SHA256),
            ("x-amz-date", "20130524T000000Z"),
            (
                "Authorization",
                "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request,SignedHeaders=host;range;x-amz-content-sha256;x-amz-date,Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41",
            ),
        ])
        .unwrap();
        let query = QueryParams::parse("").unwrap();
        let request = SigV4Request {
            method: "GET",
            raw_path: "/test.txt",
            raw_query: None,
            query: &query,
            headers: &headers,
        };
        let expected_canonical = concat!(
            "GET\n/test.txt\n\n",
            "host:examplebucket.s3.amazonaws.com\n",
            "range:bytes=0-9\n",
            "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n",
            "x-amz-date:20130524T000000Z\n\n",
            "host;range;x-amz-content-sha256;x-amz-date\n",
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            build_canonical_request(
                &request,
                &[
                    "host".to_owned(),
                    "range".to_owned(),
                    "x-amz-content-sha256".to_owned(),
                    "x-amz-date".to_owned(),
                ],
                EMPTY_SHA256,
                false,
            )
            .unwrap(),
            expected_canonical.as_bytes()
        );
        let verified = verify_header(
            &request,
            SECRET,
            &VerificationConfig {
                now: at("20130524T000000Z"),
                expected_region: Some("us-east-1".to_owned()),
                ..VerificationConfig::default()
            },
        )
        .unwrap();
        assert_eq!(verified.credential.access_key, ACCESS);
        assert_eq!(
            verified.payload_mode,
            PayloadMode::FullHash(decode_hex_32(EMPTY_SHA256.as_bytes()).unwrap())
        );
    }

    #[test]
    fn verifies_official_aws_s3_presigned_example() {
        let raw_query = concat!(
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request",
            "&X-Amz-Date=20130524T000000Z",
            "&X-Amz-Expires=86400",
            "&X-Amz-SignedHeaders=host",
            "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        );
        let query = QueryParams::parse(raw_query).unwrap();
        let headers = HeaderMap::from_pairs([("Host", "examplebucket.s3.amazonaws.com")]).unwrap();
        let request = SigV4Request {
            method: "GET",
            raw_path: "/test.txt",
            raw_query: Some(raw_query),
            query: &query,
            headers: &headers,
        };
        let expected_canonical = concat!(
            "GET\n/test.txt\n",
            "X-Amz-Algorithm=AWS4-HMAC-SHA256&",
            "X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&",
            "X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host\n",
            "host:examplebucket.s3.amazonaws.com\n\n",
            "host\nUNSIGNED-PAYLOAD"
        );
        assert_eq!(
            build_canonical_request(&request, &["host".to_owned()], "UNSIGNED-PAYLOAD", true,)
                .unwrap(),
            expected_canonical.as_bytes()
        );
        let verified = verify_presigned(
            &request,
            SECRET,
            &VerificationConfig {
                now: at("20130524T120000Z"),
                expected_region: Some("us-east-1".to_owned()),
                ..VerificationConfig::default()
            },
        )
        .unwrap();
        assert_eq!(verified.credential.access_key, ACCESS);
        assert_eq!(verified.payload_mode, PayloadMode::UnsignedPayload);
    }

    #[test]
    fn canonical_query_decodes_then_encodes_and_sorts_duplicates() {
        assert_eq!(
            canonical_query(Some("z=a+b&a=2&a=1&slash=%2F"), false).unwrap(),
            "a=1&a=2&slash=%2F&z=a%2Bb"
        );
    }

    #[test]
    fn s3_canonical_uri_preserves_path_shape_and_single_percent_encoding() {
        // S3 is the SigV4 exception: it does not normalize `//`, `.` or `..`,
        // and already escaped path octets are not encoded a second time.
        assert_eq!(
            canonical_uri("/bucket/a//./../space%20and%2fslash").unwrap(),
            "/bucket/a//./../space%20and%2Fslash"
        );
    }

    #[test]
    fn canonical_headers_collapse_spaces_and_join_duplicates() {
        let headers = HeaderMap::from_pairs([
            ("Host", " example.com "),
            ("X-Test", " a  b\t c "),
            ("X-Test", "d"),
        ])
        .unwrap();
        assert_eq!(
            canonical_headers(&headers, &["host".into(), "x-test".into()]).unwrap(),
            b"host:example.com\nx-test:a b c,d\n"
        );
    }

    #[test]
    fn payload_full_hash_detects_tampering() {
        let mode = PayloadMode::FullHash(Sha256::digest(b"correct").into());
        assert!(mode.verify_body(b"correct").is_ok());
        assert_eq!(
            mode.verify_body(b"tampered"),
            Err(SigV4Error::PayloadHashMismatch)
        );
    }

    #[test]
    fn rejects_expired_presign_before_crypto() {
        let raw_query = concat!(
            "X-Amz-Algorithm=AWS4-HMAC-SHA256",
            "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request",
            "&X-Amz-Date=20130524T000000Z&X-Amz-Expires=1&X-Amz-SignedHeaders=host",
            "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
        );
        let query = QueryParams::parse(raw_query).unwrap();
        let headers = HeaderMap::from_pairs([("Host", "examplebucket.s3.amazonaws.com")]).unwrap();
        let result = verify_presigned(
            &SigV4Request {
                method: "GET",
                raw_path: "/test.txt",
                raw_query: Some(raw_query),
                query: &query,
                headers: &headers,
            },
            SECRET,
            &VerificationConfig {
                now: at("20130524T000002Z"),
                ..VerificationConfig::default()
            },
        );
        assert!(matches!(result, Err(SigV4Error::PresignedUrlExpired)));
    }
}
