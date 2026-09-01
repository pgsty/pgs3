//! Incremental decoder for the S3 `aws-chunked` content encoding.
//!
//! Signed chunk data is held only until its chunk signature verifies, then
//! appended to the caller's output buffer. Unsigned-trailer mode necessarily
//! authenticates its checksum only at the final trailer; callers must not make
//! the upload visible until `DecodeStatus::Done` is returned.

use std::fmt;

use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use crc::{Algorithm, CRC_32_ISCSI, Crc};
use sha1::Sha1;
use sha2::{Digest, Sha256};

use super::sigv4::{
    SigV4Error, StreamingSigningContext, constant_time_eq, decode_signature_hex, hex_lower,
    verify_hmac,
};

const EMPTY_SHA256: &str = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

/// Signed chunks must remain private until their signature verifies. Keep the
/// resulting per-connection authentication buffer bounded even if a caller
/// supplies more permissive `ChunkedLimits`.
const MAX_BUFFERED_CHUNK_BYTES: usize = 1024 * 1024;

/// CRC-64/NVME parameters from the NVMe specification / reveng catalogue.
/// The catalogue check value for `123456789` is `0xae8b14860a799888`.
const CRC_64_NVME_ALGORITHM: Algorithm<u64> = Algorithm {
    width: 64,
    poly: 0xad93_d235_94c9_3659,
    init: u64::MAX,
    refin: true,
    refout: true,
    xorout: u64::MAX,
    check: 0xae8b_1486_0a79_9888,
    residue: 0xf310_303b_2b6f_6e42,
};

pub(crate) const CRC32C: Crc<u32> = Crc::<u32>::new(&CRC_32_ISCSI);
pub(crate) const CRC64NVME: Crc<u64> = Crc::<u64>::new(&CRC_64_NVME_ALGORITHM);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ChunkedLimits {
    pub max_chunk_header_bytes: usize,
    pub max_chunk_bytes: usize,
    pub max_decoded_bytes: u64,
    pub max_trailer_bytes: usize,
    pub max_trailers: usize,
    pub expected_decoded_length: Option<u64>,
}

impl Default for ChunkedLimits {
    fn default() -> Self {
        Self {
            max_chunk_header_bytes: 1024,
            max_chunk_bytes: MAX_BUFFERED_CHUNK_BYTES,
            max_decoded_bytes: 5 * 1024 * 1024 * 1024,
            max_trailer_bytes: 16 * 1024,
            max_trailers: 8,
            expected_decoded_length: None,
        }
    }
}

#[derive(Clone, Debug)]
pub enum AwsChunkedMode {
    Signed(StreamingSigningContext),
    UnsignedTrailer { declared_trailers: Vec<String> },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DecodeStatus {
    NeedMore,
    Done,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DecodedTrailer {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ChunkedError {
    InputAfterEnd,
    HeaderTooLarge,
    InvalidChunkHeader,
    ChunkTooLarge,
    MissingChunkSignature,
    UnexpectedChunkSignature,
    ChunkSignatureMismatch,
    MissingChunkTerminator,
    DecodedBodyTooLarge,
    DecodedLengthMismatch { expected: u64, actual: u64 },
    TrailerTooLarge,
    TooManyTrailers,
    InvalidTrailer,
    DuplicateTrailer(String),
    UndeclaredTrailer(String),
    MissingTrailer(String),
    UnsupportedChecksum(String),
    InvalidChecksumEncoding(String),
    ChecksumMismatch(String),
    UnexpectedTrailer,
}

impl fmt::Display for ChunkedError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InputAfterEnd => f.write_str("bytes follow the final aws-chunked trailer"),
            Self::HeaderTooLarge => f.write_str("aws-chunked header line is too large"),
            Self::InvalidChunkHeader => f.write_str("invalid aws-chunked size or extension"),
            Self::ChunkTooLarge => f.write_str("aws-chunked data chunk exceeds its limit"),
            Self::MissingChunkSignature => f.write_str("signed aws-chunked chunk has no signature"),
            Self::UnexpectedChunkSignature => {
                f.write_str("unsigned aws-chunked chunk unexpectedly has a signature")
            }
            Self::ChunkSignatureMismatch => {
                f.write_str("aws-chunked signature chain does not match")
            }
            Self::MissingChunkTerminator => f.write_str("aws-chunked data lacks its trailing CRLF"),
            Self::DecodedBodyTooLarge => f.write_str("decoded aws-chunked body exceeds its limit"),
            Self::DecodedLengthMismatch { expected, actual } => {
                write!(
                    f,
                    "decoded body length {actual} does not match declared length {expected}"
                )
            }
            Self::TrailerTooLarge => f.write_str("aws-chunked trailers exceed their size limit"),
            Self::TooManyTrailers => f.write_str("aws-chunked body has too many trailers"),
            Self::InvalidTrailer => f.write_str("invalid aws-chunked trailer field"),
            Self::DuplicateTrailer(name) => write!(f, "duplicate aws-chunked trailer {name}"),
            Self::UndeclaredTrailer(name) => write!(f, "undeclared aws-chunked trailer {name}"),
            Self::MissingTrailer(name) => {
                write!(f, "declared aws-chunked trailer is missing: {name}")
            }
            Self::UnsupportedChecksum(name) => {
                write!(f, "unsupported aws-chunked checksum: {name}")
            }
            Self::InvalidChecksumEncoding(name) => {
                write!(f, "invalid base64 checksum in aws-chunked trailer {name}")
            }
            Self::ChecksumMismatch(name) => {
                write!(f, "aws-chunked checksum does not match: {name}")
            }
            Self::UnexpectedTrailer => f.write_str("signed non-trailer payload contains trailers"),
        }
    }
}

impl std::error::Error for ChunkedError {}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Phase {
    Header,
    Data,
    DataCrlf,
    Trailers,
    Done,
}

struct CurrentChunk {
    size: usize,
    data: Vec<u8>,
    signature: Option<[u8; 32]>,
}

/// Stateful, bounded aws-chunked decoder. Call `push` with arbitrary fragments;
/// decoded complete chunks are appended to `output`.
pub struct AwsChunkedDecoder {
    mode: AwsChunkedMode,
    limits: ChunkedLimits,
    phase: Phase,
    input: Vec<u8>,
    offset: usize,
    current: Option<CurrentChunk>,
    decoded_bytes: u64,
    crc32: crc32fast::Hasher,
    crc32c: crc::Digest<'static, u32>,
    crc64nvme: crc::Digest<'static, u64>,
    sha1: Sha1,
    sha256: Sha256,
    trailers: Vec<DecodedTrailer>,
    trailer_bytes: usize,
    previous_signature: Option<[u8; 32]>,
}

impl fmt::Debug for AwsChunkedDecoder {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("AwsChunkedDecoder")
            .field("mode", &self.mode)
            .field("limits", &self.limits)
            .field("phase", &self.phase)
            .field("buffered_bytes", &(self.input.len() - self.offset))
            .field("decoded_bytes", &self.decoded_bytes)
            .field("trailers", &self.trailers)
            .finish()
    }
}

impl AwsChunkedDecoder {
    pub fn new(mode: AwsChunkedMode, limits: ChunkedLimits) -> Result<Self, ChunkedError> {
        let previous_signature = match &mode {
            AwsChunkedMode::Signed(context) => Some(context.seed_signature),
            AwsChunkedMode::UnsignedTrailer { declared_trailers } => {
                validate_declarations(declared_trailers)?;
                None
            }
        };
        Ok(Self {
            mode,
            limits,
            phase: Phase::Header,
            input: Vec::new(),
            offset: 0,
            current: None,
            decoded_bytes: 0,
            crc32: crc32fast::Hasher::new(),
            crc32c: CRC32C.digest(),
            crc64nvme: CRC64NVME.digest(),
            sha1: Sha1::new(),
            sha256: Sha256::new(),
            trailers: Vec::new(),
            trailer_bytes: 0,
            previous_signature,
        })
    }

    #[must_use]
    #[allow(dead_code)]
    pub fn decoded_bytes(&self) -> u64 {
        self.decoded_bytes
    }

    #[must_use]
    #[allow(dead_code)]
    pub fn trailers(&self) -> &[DecodedTrailer] {
        &self.trailers
    }

    #[must_use]
    #[allow(dead_code)]
    pub fn is_done(&self) -> bool {
        self.phase == Phase::Done
    }

    pub fn push(
        &mut self,
        bytes: &[u8],
        output: &mut Vec<u8>,
    ) -> Result<DecodeStatus, ChunkedError> {
        if self.phase == Phase::Done {
            return if bytes.is_empty() {
                Ok(DecodeStatus::Done)
            } else {
                Err(ChunkedError::InputAfterEnd)
            };
        }
        self.compact();
        self.input.extend_from_slice(bytes);

        loop {
            match self.phase {
                Phase::Header => {
                    let Some(line) = self.take_line(self.limits.max_chunk_header_bytes, false)?
                    else {
                        return Ok(DecodeStatus::NeedMore);
                    };
                    let (size, signature) = parse_chunk_header(&line)?;
                    if size > self.limits.max_chunk_bytes.min(MAX_BUFFERED_CHUNK_BYTES) {
                        return Err(ChunkedError::ChunkTooLarge);
                    }
                    let declared_bytes =
                        u64::try_from(size).map_err(|_| ChunkedError::DecodedBodyTooLarge)?;
                    let decoded_after_chunk = self
                        .decoded_bytes
                        .checked_add(declared_bytes)
                        .ok_or(ChunkedError::DecodedBodyTooLarge)?;
                    if decoded_after_chunk > self.limits.max_decoded_bytes
                        || self
                            .limits
                            .expected_decoded_length
                            .is_some_and(|expected| decoded_after_chunk > expected)
                    {
                        return Err(ChunkedError::DecodedBodyTooLarge);
                    }
                    match self.mode {
                        AwsChunkedMode::Signed(_) if signature.is_none() => {
                            return Err(ChunkedError::MissingChunkSignature);
                        }
                        AwsChunkedMode::UnsignedTrailer { .. } if signature.is_some() => {
                            return Err(ChunkedError::UnexpectedChunkSignature);
                        }
                        _ => {}
                    }
                    if size == 0 {
                        if let Some(signature) = signature {
                            self.verify_chunk_signature(&[], &signature)?;
                            self.previous_signature = Some(signature);
                        }
                        self.phase = Phase::Trailers;
                    } else {
                        self.current = Some(CurrentChunk {
                            size,
                            // A peer may stop after announcing a large chunk.
                            // Allocate only for bytes that actually arrive.
                            data: Vec::new(),
                            signature,
                        });
                        self.phase = Phase::Data;
                    }
                }
                Phase::Data => {
                    let current = self.current.as_mut().expect("data phase has a chunk");
                    let remaining = current.size - current.data.len();
                    let available = self.input.len() - self.offset;
                    if available == 0 {
                        return Ok(DecodeStatus::NeedMore);
                    }
                    let count = remaining.min(available);
                    current
                        .data
                        .extend_from_slice(&self.input[self.offset..self.offset + count]);
                    self.offset += count;
                    if current.data.len() == current.size {
                        self.phase = Phase::DataCrlf;
                    }
                }
                Phase::DataCrlf => {
                    if self.input.len() - self.offset < 2 {
                        return Ok(DecodeStatus::NeedMore);
                    }
                    if &self.input[self.offset..self.offset + 2] != b"\r\n" {
                        return Err(ChunkedError::MissingChunkTerminator);
                    }
                    self.offset += 2;
                    let current = self.current.take().expect("CRLF phase has a chunk");
                    if let Some(signature) = current.signature {
                        self.verify_chunk_signature(&current.data, &signature)?;
                        self.previous_signature = Some(signature);
                    }
                    self.accept_decoded(&current.data, output)?;
                    self.phase = Phase::Header;
                }
                Phase::Trailers => {
                    let Some(line) = self.take_line(self.limits.max_trailer_bytes, true)? else {
                        return Ok(DecodeStatus::NeedMore);
                    };
                    self.trailer_bytes = self
                        .trailer_bytes
                        .checked_add(line.len() + 2)
                        .ok_or(ChunkedError::TrailerTooLarge)?;
                    if self.trailer_bytes > self.limits.max_trailer_bytes {
                        return Err(ChunkedError::TrailerTooLarge);
                    }
                    if line.is_empty() {
                        self.finish_trailers()?;
                        self.phase = Phase::Done;
                        if self.input.len() != self.offset {
                            return Err(ChunkedError::InputAfterEnd);
                        }
                        return Ok(DecodeStatus::Done);
                    }
                    self.accept_trailer(&line)?;
                }
                Phase::Done => return Ok(DecodeStatus::Done),
            }
        }
    }

    /// Signals end-of-input and rejects a truncated stream.
    pub fn finish(&mut self) -> Result<(), ChunkedError> {
        if self.phase == Phase::Done {
            Ok(())
        } else {
            match self.phase {
                Phase::DataCrlf => Err(ChunkedError::MissingChunkTerminator),
                Phase::Trailers => Err(ChunkedError::InvalidTrailer),
                Phase::Header | Phase::Data => Err(ChunkedError::InvalidChunkHeader),
                Phase::Done => Ok(()),
            }
        }
    }

    fn accept_decoded(&mut self, data: &[u8], output: &mut Vec<u8>) -> Result<(), ChunkedError> {
        let size = u64::try_from(data.len()).map_err(|_| ChunkedError::DecodedBodyTooLarge)?;
        self.decoded_bytes = self
            .decoded_bytes
            .checked_add(size)
            .ok_or(ChunkedError::DecodedBodyTooLarge)?;
        if self.decoded_bytes > self.limits.max_decoded_bytes
            || self
                .limits
                .expected_decoded_length
                .is_some_and(|expected| self.decoded_bytes > expected)
        {
            return Err(ChunkedError::DecodedBodyTooLarge);
        }
        self.crc32.update(data);
        self.crc32c.update(data);
        self.crc64nvme.update(data);
        self.sha1.update(data);
        self.sha256.update(data);
        output.extend_from_slice(data);
        Ok(())
    }

    fn verify_chunk_signature(
        &self,
        data: &[u8],
        signature: &[u8; 32],
    ) -> Result<(), ChunkedError> {
        let AwsChunkedMode::Signed(context) = &self.mode else {
            return Err(ChunkedError::UnexpectedChunkSignature);
        };
        let previous = self
            .previous_signature
            .as_ref()
            .expect("signed decoder has a seed signature");
        let data_hash: [u8; 32] = Sha256::digest(data).into();
        let string_to_sign = format!(
            "AWS4-HMAC-SHA256-PAYLOAD\n{}\n{}\n{}\n{}\n{}",
            context.amz_date,
            context.credential_scope,
            hex_lower(previous),
            EMPTY_SHA256,
            hex_lower(&data_hash),
        );
        verify_hmac(&context.signing_key, string_to_sign.as_bytes(), signature).map_err(|error| {
            match error {
                SigV4Error::SignatureMismatch => ChunkedError::ChunkSignatureMismatch,
                _ => ChunkedError::ChunkSignatureMismatch,
            }
        })
    }

    fn accept_trailer(&mut self, line: &[u8]) -> Result<(), ChunkedError> {
        if matches!(self.mode, AwsChunkedMode::Signed(_)) {
            return Err(ChunkedError::UnexpectedTrailer);
        }
        if self.trailers.len() >= self.limits.max_trailers {
            return Err(ChunkedError::TooManyTrailers);
        }
        if matches!(line.first(), Some(b' ' | b'\t')) {
            return Err(ChunkedError::InvalidTrailer);
        }
        let colon = line
            .iter()
            .position(|byte| *byte == b':')
            .ok_or(ChunkedError::InvalidTrailer)?;
        let name = &line[..colon];
        if name.is_empty()
            || !name
                .iter()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || *byte == b'-')
        {
            return Err(ChunkedError::InvalidTrailer);
        }
        let name = std::str::from_utf8(name)
            .map_err(|_| ChunkedError::InvalidTrailer)?
            .to_owned();
        let mut value = trim_ows(&line[colon + 1..]);
        // AWS documents an SDK variation that writes LF immediately before the
        // trailer line's CRLF. Accept exactly that single optional LF.
        if value.ends_with(b"\n") {
            value = &value[..value.len() - 1];
        }
        if value.is_empty() || !value.iter().all(|byte| byte.is_ascii_graphic()) {
            return Err(ChunkedError::InvalidTrailer);
        }
        if self.trailers.iter().any(|trailer| trailer.name == name) {
            return Err(ChunkedError::DuplicateTrailer(name));
        }
        let AwsChunkedMode::UnsignedTrailer { declared_trailers } = &self.mode else {
            unreachable!()
        };
        if !declared_trailers.iter().any(|declared| declared == &name) {
            return Err(ChunkedError::UndeclaredTrailer(name));
        }
        self.trailers.push(DecodedTrailer {
            name,
            value: std::str::from_utf8(value)
                .map_err(|_| ChunkedError::InvalidTrailer)?
                .to_owned(),
        });
        Ok(())
    }

    fn finish_trailers(&self) -> Result<(), ChunkedError> {
        if let Some(expected) = self.limits.expected_decoded_length
            && self.decoded_bytes != expected
        {
            return Err(ChunkedError::DecodedLengthMismatch {
                expected,
                actual: self.decoded_bytes,
            });
        }
        match &self.mode {
            AwsChunkedMode::Signed(_) => {
                if self.trailers.is_empty() {
                    Ok(())
                } else {
                    Err(ChunkedError::UnexpectedTrailer)
                }
            }
            AwsChunkedMode::UnsignedTrailer { declared_trailers } => {
                for declared in declared_trailers {
                    let trailer = self
                        .trailers
                        .iter()
                        .find(|trailer| &trailer.name == declared)
                        .ok_or_else(|| ChunkedError::MissingTrailer(declared.clone()))?;
                    let (expected, encoded_length) = self
                        .calculated_checksum(declared)
                        .ok_or_else(|| ChunkedError::UnsupportedChecksum(declared.clone()))?;
                    if trailer.value.len() != encoded_length {
                        return Err(ChunkedError::InvalidChecksumEncoding(declared.clone()));
                    }
                    let supplied = BASE64
                        .decode(&trailer.value)
                        .map_err(|_| ChunkedError::InvalidChecksumEncoding(declared.clone()))?;
                    if supplied.len() != expected.len() {
                        return Err(ChunkedError::InvalidChecksumEncoding(declared.clone()));
                    }
                    if !constant_time_eq(&supplied, &expected) {
                        return Err(ChunkedError::ChecksumMismatch(declared.clone()));
                    }
                }
                Ok(())
            }
        }
    }

    fn calculated_checksum(&self, name: &str) -> Option<(Vec<u8>, usize)> {
        match name {
            "x-amz-checksum-crc32" => {
                Some((self.crc32.clone().finalize().to_be_bytes().to_vec(), 8))
            }
            "x-amz-checksum-crc32c" => {
                Some((self.crc32c.clone().finalize().to_be_bytes().to_vec(), 8))
            }
            "x-amz-checksum-sha1" => Some((self.sha1.clone().finalize().to_vec(), 28)),
            "x-amz-checksum-sha256" => Some((self.sha256.clone().finalize().to_vec(), 44)),
            "x-amz-checksum-crc64nvme" => {
                Some((self.crc64nvme.clone().finalize().to_be_bytes().to_vec(), 12))
            }
            _ => None,
        }
    }

    fn take_line(&mut self, limit: usize, trailer: bool) -> Result<Option<Vec<u8>>, ChunkedError> {
        let available = &self.input[self.offset..];
        let Some(position) = available.windows(2).position(|window| window == b"\r\n") else {
            if available.len() > limit {
                return Err(if trailer {
                    ChunkedError::TrailerTooLarge
                } else {
                    ChunkedError::HeaderTooLarge
                });
            }
            return Ok(None);
        };
        if position > limit {
            return Err(if trailer {
                ChunkedError::TrailerTooLarge
            } else {
                ChunkedError::HeaderTooLarge
            });
        }
        let line = available[..position].to_vec();
        self.offset += position + 2;
        Ok(Some(line))
    }

    fn compact(&mut self) {
        if self.offset == self.input.len() {
            self.input.clear();
            self.offset = 0;
        } else if self.offset > 64 * 1024 && self.offset > self.input.len() / 2 {
            self.input.drain(..self.offset);
            self.offset = 0;
        }
    }
}

fn parse_chunk_header(line: &[u8]) -> Result<(usize, Option<[u8; 32]>), ChunkedError> {
    let mut fields = line.split(|byte| *byte == b';');
    let size = fields.next().ok_or(ChunkedError::InvalidChunkHeader)?;
    if size.is_empty() || size.len() > 16 || !size.iter().all(u8::is_ascii_hexdigit) {
        return Err(ChunkedError::InvalidChunkHeader);
    }
    let size = std::str::from_utf8(size)
        .ok()
        .and_then(|value| u64::from_str_radix(value, 16).ok())
        .and_then(|size| usize::try_from(size).ok())
        .ok_or(ChunkedError::InvalidChunkHeader)?;
    let mut signature = None;
    for extension in fields {
        let (name, value) = split_once(extension, b'=').ok_or(ChunkedError::InvalidChunkHeader)?;
        if name != b"chunk-signature" || signature.is_some() {
            return Err(ChunkedError::InvalidChunkHeader);
        }
        signature =
            Some(decode_signature_hex(value).map_err(|_| ChunkedError::InvalidChunkHeader)?);
    }
    Ok((size, signature))
}

fn validate_declarations(declared: &[String]) -> Result<(), ChunkedError> {
    if declared.is_empty() {
        return Err(ChunkedError::MissingTrailer("x-amz-trailer".to_owned()));
    }
    for (index, name) in declared.iter().enumerate() {
        if !matches!(
            name.as_str(),
            "x-amz-checksum-crc32"
                | "x-amz-checksum-crc32c"
                | "x-amz-checksum-sha1"
                | "x-amz-checksum-sha256"
                | "x-amz-checksum-crc64nvme"
        ) {
            return Err(ChunkedError::UnsupportedChecksum(name.clone()));
        }
        if declared[..index].contains(name) {
            return Err(ChunkedError::DuplicateTrailer(name.clone()));
        }
    }
    Ok(())
}

fn trim_ows(mut value: &[u8]) -> &[u8] {
    while matches!(value.first(), Some(b' ' | b'\t')) {
        value = &value[1..];
    }
    while matches!(value.last(), Some(b' ' | b'\t')) {
        value = &value[..value.len() - 1];
    }
    value
}

fn split_once(value: &[u8], delimiter: u8) -> Option<(&[u8], &[u8])> {
    let index = value.iter().position(|byte| *byte == delimiter)?;
    Some((&value[..index], &value[index + 1..]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::sigv4::{CredentialScope, derive_signing_key};

    const ZERO_SIGNATURE: &str = "0000000000000000000000000000000000000000000000000000000000000000";

    fn inert_signing_context() -> StreamingSigningContext {
        StreamingSigningContext {
            signing_key: [1; 32],
            amz_date: "20200101T000000Z".to_owned(),
            credential_scope: "20200101/us-east-1/s3/aws4_request".to_owned(),
            seed_signature: [2; 32],
        }
    }

    #[test]
    fn verifies_official_aws_signed_chunk_chain_incrementally() {
        let credential = CredentialScope {
            access_key: "AKIAIOSFODNN7EXAMPLE".to_owned(),
            date: "20130524".to_owned(),
            region: "us-east-1".to_owned(),
            service: "s3".to_owned(),
        };
        let context = StreamingSigningContext {
            signing_key: derive_signing_key(
                b"wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                &credential,
            ),
            amz_date: "20130524T000000Z".to_owned(),
            credential_scope: credential.scope(),
            seed_signature: decode_signature_hex(
                b"4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9",
            )
            .unwrap(),
        };
        let mut encoded = Vec::new();
        encoded.extend_from_slice(b"10000;chunk-signature=ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648\r\n");
        encoded.extend(std::iter::repeat_n(b'a', 65_536));
        encoded.extend_from_slice(b"\r\n400;chunk-signature=0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497\r\n");
        encoded.extend(std::iter::repeat_n(b'a', 1_024));
        encoded.extend_from_slice(b"\r\n0;chunk-signature=b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9\r\n\r\n");

        let mut decoder = AwsChunkedDecoder::new(
            AwsChunkedMode::Signed(context),
            ChunkedLimits {
                expected_decoded_length: Some(66_560),
                ..ChunkedLimits::default()
            },
        )
        .unwrap();
        let mut decoded = Vec::new();
        let mut status = DecodeStatus::NeedMore;
        for fragment in encoded.chunks(997) {
            status = decoder.push(fragment, &mut decoded).unwrap();
        }
        assert_eq!(status, DecodeStatus::Done);
        assert_eq!(decoded, vec![b'a'; 66_560]);
    }

    #[test]
    fn validates_all_aws_checksum_trailers_incrementally() {
        let mut decoder = AwsChunkedDecoder::new(
            AwsChunkedMode::UnsignedTrailer {
                declared_trailers: vec![
                    "x-amz-checksum-crc32".to_owned(),
                    "x-amz-checksum-crc32c".to_owned(),
                    "x-amz-checksum-sha1".to_owned(),
                    "x-amz-checksum-sha256".to_owned(),
                    "x-amz-checksum-crc64nvme".to_owned(),
                ],
            },
            ChunkedLimits {
                expected_decoded_length: Some(9),
                ..ChunkedLimits::default()
            },
        )
        .unwrap();
        // `123456789` is the standard CRC catalogue check vector.  In
        // particular CRC32C is e3069283 and CRC64/NVME is ae8b14860a799888.
        let encoded = concat!(
            "4\r\n1234\r\n5\r\n56789\r\n0\r\n",
            "x-amz-checksum-crc32:y/Q5Jg==\r\n",
            "x-amz-checksum-crc32c:4waSgw==\r\n",
            "x-amz-checksum-sha1:98O8HYCOBHMq32eZZczDTKeuNEE=\r\n",
            "x-amz-checksum-sha256:FeKw08M4keuw8e9gnsQZQgwg4yDOlMZfvIwzEkSOsiU=\r\n",
            "x-amz-checksum-crc64nvme:rosUhgp5mIg=\r\n",
            "\r\n"
        );
        let mut decoded = Vec::new();
        for fragment in encoded.as_bytes().chunks(1) {
            decoder.push(fragment, &mut decoded).unwrap();
        }
        assert!(decoder.is_done());
        assert_eq!(decoded, b"123456789");
        assert_eq!(decoder.trailers().len(), 5);
    }

    #[test]
    fn crc_catalog_vectors_are_independent_of_fragmentation() {
        let mut crc32c = CRC32C.digest();
        let mut crc64nvme = CRC64NVME.digest();
        for byte in b"123456789" {
            crc32c.update(std::slice::from_ref(byte));
            crc64nvme.update(std::slice::from_ref(byte));
        }
        assert_eq!(crc32c.finalize(), 0xe306_9283);
        assert_eq!(crc64nvme.finalize(), 0xae8b_1486_0a79_9888);
    }

    #[test]
    fn rejects_checksum_mismatch() {
        let mut decoder = AwsChunkedDecoder::new(
            AwsChunkedMode::UnsignedTrailer {
                declared_trailers: vec!["x-amz-checksum-crc32".to_owned()],
            },
            ChunkedLimits::default(),
        )
        .unwrap();
        let mut output = Vec::new();
        let result = decoder.push(
            b"3\r\nabc\r\n0\r\nx-amz-checksum-crc32:AAAAAA==\r\n\r\n",
            &mut output,
        );
        assert!(matches!(
            result,
            Err(ChunkedError::ChecksumMismatch(name)) if name == "x-amz-checksum-crc32"
        ));
    }

    #[test]
    fn rejects_wrong_checksum_base64_length_before_comparison() {
        let mut decoder = AwsChunkedDecoder::new(
            AwsChunkedMode::UnsignedTrailer {
                declared_trailers: vec!["x-amz-checksum-crc64nvme".to_owned()],
            },
            ChunkedLimits::default(),
        )
        .unwrap();
        let mut output = Vec::new();
        let result = decoder.push(
            b"3\r\nabc\r\n0\r\nx-amz-checksum-crc64nvme:AAAA\r\n\r\n",
            &mut output,
        );
        assert!(matches!(
            result,
            Err(ChunkedError::InvalidChecksumEncoding(name))
                if name == "x-amz-checksum-crc64nvme"
        ));
    }

    #[test]
    fn rejects_checksum_name_variants_not_defined_by_s3() {
        let error = AwsChunkedDecoder::new(
            AwsChunkedMode::UnsignedTrailer {
                declared_trailers: vec!["x-amz-checksum-crc64-nvme".to_owned()],
            },
            ChunkedLimits::default(),
        )
        .unwrap_err();
        assert_eq!(
            error,
            ChunkedError::UnsupportedChecksum("x-amz-checksum-crc64-nvme".to_owned())
        );
    }

    #[test]
    fn signed_chunk_declarations_are_lazy_and_hard_capped() {
        let limits = ChunkedLimits {
            // The authentication-buffer ceiling is deliberately not
            // relaxable through a caller-provided protocol limit.
            max_chunk_bytes: usize::MAX,
            ..ChunkedLimits::default()
        };
        let mut decoder =
            AwsChunkedDecoder::new(AwsChunkedMode::Signed(inert_signing_context()), limits)
                .unwrap();
        let header = format!("{MAX_BUFFERED_CHUNK_BYTES:x};chunk-signature={ZERO_SIGNATURE}\r\n");
        let mut output = Vec::new();
        assert_eq!(
            decoder.push(header.as_bytes(), &mut output).unwrap(),
            DecodeStatus::NeedMore
        );
        let current = decoder.current.as_ref().unwrap();
        assert_eq!(current.size, MAX_BUFFERED_CHUNK_BYTES);
        assert_eq!(current.data.capacity(), 0);
        assert!(output.is_empty());

        let mut decoder =
            AwsChunkedDecoder::new(AwsChunkedMode::Signed(inert_signing_context()), limits)
                .unwrap();
        let header = format!(
            "{:x};chunk-signature={ZERO_SIGNATURE}\r\n",
            MAX_BUFFERED_CHUNK_BYTES + 1
        );
        assert_eq!(
            decoder.push(header.as_bytes(), &mut output),
            Err(ChunkedError::ChunkTooLarge)
        );
        assert!(decoder.current.is_none());
        assert!(output.is_empty());
    }

    #[test]
    fn rejects_declared_chunk_beyond_decoded_budget_before_buffering() {
        let mut decoder = AwsChunkedDecoder::new(
            AwsChunkedMode::Signed(inert_signing_context()),
            ChunkedLimits {
                expected_decoded_length: Some(1),
                ..ChunkedLimits::default()
            },
        )
        .unwrap();
        let header = format!("2;chunk-signature={ZERO_SIGNATURE}\r\n");
        let mut output = Vec::new();
        assert_eq!(
            decoder.push(header.as_bytes(), &mut output),
            Err(ChunkedError::DecodedBodyTooLarge)
        );
        assert!(decoder.current.is_none());
        assert!(output.is_empty());
    }

    #[test]
    fn does_not_release_a_bad_signed_chunk() {
        let mut decoder = AwsChunkedDecoder::new(
            AwsChunkedMode::Signed(inert_signing_context()),
            ChunkedLimits::default(),
        )
        .unwrap();
        let mut output = Vec::new();
        let error = decoder
            .push(
                format!("3;chunk-signature={ZERO_SIGNATURE}\r\nabc\r\n").as_bytes(),
                &mut output,
            )
            .unwrap_err();
        assert_eq!(error, ChunkedError::ChunkSignatureMismatch);
        assert_eq!(decoder.decoded_bytes(), 0);
        assert!(output.is_empty());
    }
}
