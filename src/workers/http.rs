//! Single-threaded, nonblocking HTTP/S3 worker reactor.
//!
//! PostgreSQL and SPI are only touched on the background worker's main thread.
//! A connection can serve sequential HTTP/1.1 requests.  Ambiguous framing,
//! unread request bytes, protocol/application errors, and explicit close
//! requests still terminate the connection after one bounded response.

use pgrx::bgworkers::{BackgroundWorker, SignalWakeFlags};
use pgrx::prelude::*;
use std::borrow::Cow;
use std::collections::BTreeMap;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, TcpListener, TcpStream};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::protocol::http::{HeadLimits, RequestHead, RequestHeadParser};
use crate::protocol::xml::{S3ErrorResponse, serialize_error};
use crate::s3::{BodySession, HeadOutcome as S3HeadOutcome, PgS3Service, ServiceResponse};

use super::{MetricDelta, WorkerState, unpack_child_argument};

const MAX_CONNECTIONS: usize = 256;
const MAX_HEAD_BYTES: usize = 64 * 1024;
const MAX_RESPONSE_HEAD_BYTES: usize = 64 * 1024;
const MAX_RESPONSE_HEADERS: usize = 128;
const MAX_HTTP_BODY_BYTES: u64 = 5 * 1024 * 1024 * 1024;
const MAX_HTTP_WIRE_BYTES: u64 = MAX_HTTP_BODY_BYTES + 256 * 1024 * 1024;
const MAX_CHUNK_LINE_BYTES: usize = 8 * 1024;
const MAX_TRAILER_LINE_BYTES: usize = 16 * 1024;
const MAX_TRAILER_BYTES: usize = 64 * 1024;
const MAX_TRAILERS: usize = 100;
const IO_CHUNK_BYTES: usize = 64 * 1024;
const MAX_IO_STEPS_PER_TICK: usize = 8;
const HEAD_IDLE_TIMEOUT: Duration = Duration::from_secs(5);
const BODY_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const WRITE_IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const REACTOR_MAX_SLEEP: Duration = Duration::from_secs(1);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(1);
const CONTINUE_RESPONSE: &[u8] = b"HTTP/1.1 100 Continue\r\n\r\n";

static ERROR_REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Eq, PartialEq)]
struct BindConfig {
    address: IpAddr,
    port: u16,
}

impl BindConfig {
    fn load() -> Result<Self, String> {
        let raw = crate::config::listen_addr();
        let address = raw
            .parse::<IpAddr>()
            .map_err(|_| format!("pgs3.listen_addr is not an IPv4 or IPv6 address: {raw}"))?;
        Ok(Self {
            address,
            port: crate::config::port(),
        })
    }
}

/// Refresh PostgreSQL configuration before rebuilding a GUC-backed value.
/// Keeping the order in one helper prevents a future SIGHUP path from
/// accidentally snapshotting the old setting immediately before reload.
fn rebuild_after_reload<T>(reload: impl FnOnce(), rebuild: impl FnOnce() -> T) -> T {
    reload();
    rebuild()
}

enum HandlerOutcome<S> {
    Immediate(ServiceResponse),
    ReceiveBody(S),
}

/// The seam keeps framing tests independent of PostgreSQL. Production still
/// uses one concrete PgS3Service on the worker's main thread.
trait S3Handler {
    type Session;

    fn operation_name(&self, request: &RequestHead) -> &'static str;
    fn handle_head(&mut self, request: RequestHead) -> HandlerOutcome<Self::Session>;
    fn push_body(
        &mut self,
        session: &mut Self::Session,
        bytes: &[u8],
    ) -> Result<(), ServiceResponse>;
    fn finish_body(&mut self, session: &mut Self::Session) -> ServiceResponse;
    fn abort_body(&mut self, session: &mut Self::Session);
}

impl S3Handler for PgS3Service {
    type Session = Box<BodySession>;

    fn operation_name(&self, request: &RequestHead) -> &'static str {
        crate::s3::classify(request)
            .map(|operation| operation.name())
            .unwrap_or("InvalidRequest")
    }

    fn handle_head(&mut self, request: RequestHead) -> HandlerOutcome<Self::Session> {
        match PgS3Service::handle_head(self, request) {
            S3HeadOutcome::Immediate(response) => HandlerOutcome::Immediate(response),
            S3HeadOutcome::ReceiveBody(session) => HandlerOutcome::ReceiveBody(session),
        }
    }

    fn push_body(
        &mut self,
        session: &mut Self::Session,
        bytes: &[u8],
    ) -> Result<(), ServiceResponse> {
        PgS3Service::push_body(self, session.as_mut(), bytes)
    }

    fn finish_body(&mut self, session: &mut Self::Session) -> ServiceResponse {
        PgS3Service::finish_body(self, session.as_mut())
    }

    fn abort_body(&mut self, session: &mut Self::Session) {
        PgS3Service::abort_body(self, session.as_mut());
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FramingError {
    EntityTooLarge,
    InvalidChunk,
    InvalidTrailer,
    TooMuchFraming,
}

impl FramingError {
    fn response(self) -> ServiceResponse {
        match self {
            Self::EntityTooLarge => protocol_error(
                413,
                "EntityTooLarge",
                "Request entity exceeds the configured HTTP limit",
            ),
            Self::InvalidChunk | Self::InvalidTrailer | Self::TooMuchFraming => {
                protocol_error(400, "InvalidRequest", "Malformed HTTP chunked request body")
            }
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct DecodeProgress {
    consumed: usize,
    complete: bool,
}

enum BodyFraming {
    None,
    ContentLength { remaining: u64 },
    Chunked(HttpChunkedDecoder),
}

impl BodyFraming {
    fn from_head(head: &RequestHead) -> Result<Self, FramingError> {
        if head.transfer_chunked {
            return Ok(Self::Chunked(HttpChunkedDecoder::new()));
        }
        match head.content_length {
            Some(length) if length > MAX_HTTP_BODY_BYTES => Err(FramingError::EntityTooLarge),
            Some(length) => Ok(Self::ContentLength { remaining: length }),
            None => Ok(Self::None),
        }
    }

    fn push<'a>(
        &mut self,
        input: &'a [u8],
    ) -> Result<(DecodeProgress, Cow<'a, [u8]>), FramingError> {
        match self {
            Self::None => Ok((
                DecodeProgress {
                    consumed: 0,
                    complete: true,
                },
                Cow::Borrowed(&[]),
            )),
            Self::ContentLength { remaining } => {
                let count = usize::try_from((*remaining).min(input.len() as u64))
                    .expect("count is bounded by input length");
                *remaining -= count as u64;
                Ok((
                    DecodeProgress {
                        consumed: count,
                        complete: *remaining == 0,
                    },
                    Cow::Borrowed(&input[..count]),
                ))
            }
            Self::Chunked(decoder) => {
                let mut decoded = Vec::with_capacity(input.len().min(IO_CHUNK_BYTES));
                let progress = decoder.push(input, &mut decoded)?;
                Ok((progress, Cow::Owned(decoded)))
            }
        }
    }

    fn is_complete(&self) -> bool {
        match self {
            Self::None => true,
            Self::ContentLength { remaining } => *remaining == 0,
            Self::Chunked(decoder) => decoder.is_complete(),
        }
    }
}

enum ChunkState {
    SizeLine(Vec<u8>),
    Data { remaining: u64 },
    DataCrLf { seen: u8 },
    TrailerLine(Vec<u8>),
    Complete,
}

struct HttpChunkedDecoder {
    state: ChunkState,
    wire_bytes: u64,
    decoded_bytes: u64,
    trailer_bytes: usize,
    trailers: usize,
}

impl HttpChunkedDecoder {
    fn new() -> Self {
        Self {
            state: ChunkState::SizeLine(Vec::new()),
            wire_bytes: 0,
            decoded_bytes: 0,
            trailer_bytes: 0,
            trailers: 0,
        }
    }

    fn is_complete(&self) -> bool {
        matches!(self.state, ChunkState::Complete)
    }

    fn push(
        &mut self,
        input: &[u8],
        decoded: &mut Vec<u8>,
    ) -> Result<DecodeProgress, FramingError> {
        decoded.clear();
        let mut offset = 0;
        while offset < input.len() && !self.is_complete() {
            let mut transition = None;
            match &mut self.state {
                ChunkState::SizeLine(line) => {
                    charge_wire(&mut self.wire_bytes, 1)?;
                    let byte = input[offset];
                    offset += 1;
                    if byte == b'\n' {
                        if line.pop() != Some(b'\r') {
                            return Err(FramingError::InvalidChunk);
                        }
                        let size = parse_chunk_size_line(line)?;
                        let total = self
                            .decoded_bytes
                            .checked_add(size)
                            .ok_or(FramingError::EntityTooLarge)?;
                        if total > MAX_HTTP_BODY_BYTES {
                            return Err(FramingError::EntityTooLarge);
                        }
                        transition = Some(if size == 0 {
                            ChunkState::TrailerLine(Vec::new())
                        } else {
                            ChunkState::Data { remaining: size }
                        });
                    } else {
                        if line.last() == Some(&b'\r') || line.len() >= MAX_CHUNK_LINE_BYTES {
                            return Err(FramingError::InvalidChunk);
                        }
                        line.push(byte);
                    }
                }
                ChunkState::Data { remaining } => {
                    let count = usize::try_from((*remaining).min((input.len() - offset) as u64))
                        .expect("count is bounded by input length");
                    charge_wire(&mut self.wire_bytes, count)?;
                    decoded.extend_from_slice(&input[offset..offset + count]);
                    offset += count;
                    *remaining -= count as u64;
                    self.decoded_bytes += count as u64;
                    if *remaining == 0 {
                        transition = Some(ChunkState::DataCrLf { seen: 0 });
                    }
                }
                ChunkState::DataCrLf { seen } => {
                    charge_wire(&mut self.wire_bytes, 1)?;
                    let expected = if *seen == 0 { b'\r' } else { b'\n' };
                    if input[offset] != expected {
                        return Err(FramingError::InvalidChunk);
                    }
                    offset += 1;
                    *seen += 1;
                    if *seen == 2 {
                        transition = Some(ChunkState::SizeLine(Vec::new()));
                    }
                }
                ChunkState::TrailerLine(line) => {
                    charge_wire(&mut self.wire_bytes, 1)?;
                    self.trailer_bytes = self
                        .trailer_bytes
                        .checked_add(1)
                        .ok_or(FramingError::TooMuchFraming)?;
                    if self.trailer_bytes > MAX_TRAILER_BYTES {
                        return Err(FramingError::TooMuchFraming);
                    }
                    let byte = input[offset];
                    offset += 1;
                    if byte == b'\n' {
                        if line.pop() != Some(b'\r') {
                            return Err(FramingError::InvalidTrailer);
                        }
                        if line.is_empty() {
                            transition = Some(ChunkState::Complete);
                        } else {
                            validate_trailer_line(line)?;
                            self.trailers += 1;
                            if self.trailers > MAX_TRAILERS {
                                return Err(FramingError::TooMuchFraming);
                            }
                            transition = Some(ChunkState::TrailerLine(Vec::new()));
                        }
                    } else {
                        if line.last() == Some(&b'\r') || line.len() >= MAX_TRAILER_LINE_BYTES {
                            return Err(FramingError::InvalidTrailer);
                        }
                        line.push(byte);
                    }
                }
                ChunkState::Complete => break,
            }
            if let Some(next) = transition {
                self.state = next;
            }
        }
        Ok(DecodeProgress {
            consumed: offset,
            complete: self.is_complete(),
        })
    }
}

fn charge_wire(wire_bytes: &mut u64, count: usize) -> Result<(), FramingError> {
    *wire_bytes = wire_bytes
        .checked_add(count as u64)
        .ok_or(FramingError::TooMuchFraming)?;
    if *wire_bytes > MAX_HTTP_WIRE_BYTES {
        return Err(FramingError::TooMuchFraming);
    }
    Ok(())
}

fn parse_chunk_size_line(line: &[u8]) -> Result<u64, FramingError> {
    let extension = line.iter().position(|byte| *byte == b';');
    let size_bytes = &line[..extension.unwrap_or(line.len())];
    if size_bytes.is_empty() || size_bytes.len() > 16 {
        return Err(FramingError::InvalidChunk);
    }
    let mut size = 0_u64;
    for byte in size_bytes {
        let digit = match byte {
            b'0'..=b'9' => byte - b'0',
            b'a'..=b'f' => byte - b'a' + 10,
            b'A'..=b'F' => byte - b'A' + 10,
            _ => return Err(FramingError::InvalidChunk),
        };
        size = size
            .checked_mul(16)
            .and_then(|value| value.checked_add(u64::from(digit)))
            .ok_or(FramingError::EntityTooLarge)?;
    }
    if let Some(start) = extension {
        validate_chunk_extensions(&line[start..])?;
    }
    Ok(size)
}

fn validate_chunk_extensions(mut bytes: &[u8]) -> Result<(), FramingError> {
    while !bytes.is_empty() {
        if bytes[0] != b';' {
            return Err(FramingError::InvalidChunk);
        }
        bytes = trim_left_ows(&bytes[1..]);
        let name_len = bytes.iter().take_while(|byte| is_tchar(**byte)).count();
        if name_len == 0 {
            return Err(FramingError::InvalidChunk);
        }
        bytes = trim_left_ows(&bytes[name_len..]);
        if bytes.first() == Some(&b'=') {
            bytes = trim_left_ows(&bytes[1..]);
            if bytes.first() == Some(&b'"') {
                let mut index = 1;
                let mut closed = false;
                while index < bytes.len() {
                    match bytes[index] {
                        b'"' => {
                            index += 1;
                            closed = true;
                            break;
                        }
                        b'\\' => {
                            index += 1;
                            if index >= bytes.len()
                                || !(bytes[index] == b'\t'
                                    || (0x20..=0x7e).contains(&bytes[index])
                                    || bytes[index] >= 0x80)
                            {
                                return Err(FramingError::InvalidChunk);
                            }
                            index += 1;
                        }
                        b'\t' | 0x20..=0x21 | 0x23..=0x5b | 0x5d..=0x7e | 0x80..=0xff => {
                            index += 1;
                        }
                        _ => return Err(FramingError::InvalidChunk),
                    }
                }
                if !closed {
                    return Err(FramingError::InvalidChunk);
                }
                bytes = trim_left_ows(&bytes[index..]);
            } else {
                let value_len = bytes.iter().take_while(|byte| is_tchar(**byte)).count();
                if value_len == 0 {
                    return Err(FramingError::InvalidChunk);
                }
                bytes = trim_left_ows(&bytes[value_len..]);
            }
        }
        if !bytes.is_empty() && bytes[0] != b';' {
            return Err(FramingError::InvalidChunk);
        }
    }
    Ok(())
}

fn validate_trailer_line(line: &[u8]) -> Result<(), FramingError> {
    if matches!(line.first(), Some(b' ' | b'\t')) {
        return Err(FramingError::InvalidTrailer);
    }
    let colon = line
        .iter()
        .position(|byte| *byte == b':')
        .ok_or(FramingError::InvalidTrailer)?;
    if colon == 0 || !line[..colon].iter().copied().all(is_tchar) {
        return Err(FramingError::InvalidTrailer);
    }
    if !line[colon + 1..]
        .iter()
        .all(|byte| *byte == b'\t' || (*byte >= 0x20 && *byte != 0x7f))
    {
        return Err(FramingError::InvalidTrailer);
    }
    Ok(())
}

fn trim_left_ows(mut bytes: &[u8]) -> &[u8] {
    while matches!(bytes.first(), Some(b' ' | b'\t')) {
        bytes = &bytes[1..];
    }
    bytes
}

fn is_tchar(byte: u8) -> bool {
    byte.is_ascii_alphanumeric()
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

fn expect_continue(request: &RequestHead) -> Result<bool, ()> {
    let mut values = request.headers.get_all("expect");
    let Some(value) = values.next() else {
        return Ok(false);
    };
    if values.next().is_some() || !value.eq_ignore_ascii_case(b"100-continue") {
        return Err(());
    }
    Ok(true)
}

enum ExchangePhase<S> {
    Head(RequestHeadParser),
    Body { session: S, framing: BodyFraming },
    Response,
    Closed,
}

struct Exchange<S> {
    phase: ExchangePhase<S>,
    response: Vec<u8>,
    status: Option<u16>,
    operation: &'static str,
    send_continue: bool,
    close_after_response: bool,
}

impl<S> Exchange<S> {
    fn new() -> Self {
        Self {
            phase: ExchangePhase::Head(RequestHeadParser::new(HeadLimits {
                max_head_bytes: MAX_HEAD_BYTES,
                ..HeadLimits::default()
            })),
            response: Vec::new(),
            status: None,
            operation: "InvalidRequest",
            send_continue: false,
            close_after_response: false,
        }
    }

    fn is_reading(&self) -> bool {
        matches!(
            self.phase,
            ExchangePhase::Head(_) | ExchangePhase::Body { .. }
        )
    }

    fn is_writing(&self) -> bool {
        matches!(self.phase, ExchangePhase::Response)
    }

    fn idle_timeout(&self) -> Duration {
        match self.phase {
            ExchangePhase::Head(_) => HEAD_IDLE_TIMEOUT,
            ExchangePhase::Body { .. } => BODY_IDLE_TIMEOUT,
            ExchangePhase::Response => WRITE_IDLE_TIMEOUT,
            ExchangePhase::Closed => Duration::ZERO,
        }
    }

    fn ingest<H>(&mut self, handler: &mut H, bytes: &[u8])
    where
        H: S3Handler<Session = S>,
    {
        let parsed = match &mut self.phase {
            ExchangePhase::Head(parser) => match parser.push(bytes) {
                Ok(parsed) => parsed,
                Err(_) => {
                    self.queue_response(protocol_error(
                        400,
                        "InvalidRequest",
                        "Malformed or oversized HTTP request head",
                    ));
                    return;
                }
            },
            ExchangePhase::Body { .. } => {
                self.ingest_body(handler, bytes);
                return;
            }
            ExchangePhase::Response | ExchangePhase::Closed => return,
        };

        let Some(request) = parsed else {
            return;
        };
        let remainder = match &mut self.phase {
            ExchangePhase::Head(parser) => parser.take_remainder(),
            _ => unreachable!("a parsed request is still in the head phase"),
        };
        self.close_after_response = request_wants_close(&request);
        self.operation = handler.operation_name(&request);
        let wants_continue = match expect_continue(&request) {
            Ok(value) => value,
            Err(()) => {
                self.queue_response(protocol_error(
                    417,
                    "InvalidRequest",
                    "Only Expect: 100-continue is supported",
                ));
                return;
            }
        };
        let framing = match BodyFraming::from_head(&request) {
            Ok(framing) => framing,
            Err(error) => {
                self.queue_response(error.response());
                return;
            }
        };
        let body_is_complete = framing.is_complete();
        match handler.handle_head(request) {
            HandlerOutcome::Immediate(response) => {
                // An immediate response cannot share a connection with bytes
                // that belonged to an unread body or a coalesced next request.
                self.close_after_response |= !body_is_complete || !remainder.is_empty();
                self.queue_response(response);
            }
            HandlerOutcome::ReceiveBody(session) => {
                self.phase = ExchangePhase::Body { session, framing };
                self.send_continue = wants_continue;
                if !remainder.is_empty() {
                    self.ingest_body(handler, &remainder);
                }
                if matches!(self.phase, ExchangePhase::Body { .. }) && self.body_is_complete() {
                    self.finish_body(handler);
                }
            }
        }
    }

    fn ingest_body<H>(&mut self, handler: &mut H, bytes: &[u8])
    where
        H: S3Handler<Session = S>,
    {
        let progress = match &mut self.phase {
            ExchangePhase::Body { framing, .. } => framing.push(bytes),
            _ => return,
        };
        let (progress, body) = match progress {
            Ok(progress) => progress,
            Err(error) => {
                self.abort_session(handler);
                self.queue_response(error.response());
                return;
            }
        };
        if progress.consumed < bytes.len() {
            // Do not reinterpret a suffix as another request in this exchange.
            // The first request is completed normally and the socket is then
            // closed, so coalesced/pipelined bytes cannot become a smuggling
            // channel or silently alter the framed entity.
            self.close_after_response = true;
        }

        if !body.is_empty() {
            let result = match &mut self.phase {
                ExchangePhase::Body { session, .. } => handler.push_body(session, body.as_ref()),
                _ => return,
            };
            if let Err(response) = result {
                // PgS3Service already cleaned its staged upload when producing
                // this response, so aborting it again would duplicate work.
                self.queue_response(response);
                return;
            }
        }
        // A suffix after the framed entity is a pipelined request. It is not
        // fed to this S3 operation; the advertised close makes its disposition
        // unambiguous.
        let _unconsumed = &bytes[progress.consumed..];
        if progress.complete {
            self.finish_body(handler);
        }
    }

    fn body_is_complete(&self) -> bool {
        matches!(
            &self.phase,
            ExchangePhase::Body { framing, .. } if framing.is_complete()
        )
    }

    fn finish_body<H>(&mut self, handler: &mut H)
    where
        H: S3Handler<Session = S>,
    {
        let response = match &mut self.phase {
            ExchangePhase::Body { session, .. } => handler.finish_body(session),
            _ => return,
        };
        self.queue_response(response);
    }

    fn eof<H>(&mut self, handler: &mut H)
    where
        H: S3Handler<Session = S>,
    {
        match self.phase {
            ExchangePhase::Head(_) => self.queue_response(protocol_error(
                400,
                "InvalidRequest",
                "Connection closed before the HTTP request head was complete",
            )),
            ExchangePhase::Body { .. } => {
                self.abort_session(handler);
                self.queue_response(protocol_error(
                    400,
                    "IncompleteBody",
                    "Connection closed before the request body was complete",
                ));
            }
            ExchangePhase::Response | ExchangePhase::Closed => {}
        }
    }

    fn timeout<H>(&mut self, handler: &mut H)
    where
        H: S3Handler<Session = S>,
    {
        match self.phase {
            ExchangePhase::Head(_) | ExchangePhase::Body { .. } => {
                self.abort_session(handler);
                self.queue_response(protocol_error(
                    408,
                    "RequestTimeout",
                    "The client did not send data within the allowed idle period",
                ));
            }
            ExchangePhase::Response | ExchangePhase::Closed => {}
        }
    }

    fn abort_session<H>(&mut self, handler: &mut H)
    where
        H: S3Handler<Session = S>,
    {
        if let ExchangePhase::Body { session, .. } = &mut self.phase {
            handler.abort_body(session);
        }
    }

    fn force_internal_error(&mut self) {
        self.send_continue = false;
        self.queue_response(protocol_error(
            500,
            "InternalError",
            "The request failed inside the pgs3 worker",
        ));
    }

    fn queue_response(&mut self, response: ServiceResponse) {
        let status = response.status;
        self.close_after_response |= status >= 400 || response_wants_close(&response);
        match serialize_response(response, self.close_after_response) {
            Ok(response) => {
                self.response = response;
                self.status = Some(status);
            }
            Err(()) => {
                self.close_after_response = true;
                self.response = fallback_internal_response();
                self.status = Some(500);
            }
        }
        self.phase = ExchangePhase::Response;
    }

    fn close(&mut self) {
        self.phase = ExchangePhase::Closed;
    }

    fn reset(&mut self) {
        *self = Self::new();
    }
}

fn header_has_token(value: &[u8], expected: &[u8]) -> bool {
    value
        .split(|byte| *byte == b',')
        .map(|token| {
            let mut token = token;
            while matches!(token.first(), Some(b' ' | b'\t')) {
                token = &token[1..];
            }
            while matches!(token.last(), Some(b' ' | b'\t')) {
                token = &token[..token.len() - 1];
            }
            token
        })
        .any(|token| token.eq_ignore_ascii_case(expected))
}

fn request_wants_close(request: &RequestHead) -> bool {
    request
        .headers
        .get_all("connection")
        .any(|value| header_has_token(value, b"close") || header_has_token(value, b"upgrade"))
}

fn response_wants_close(response: &ServiceResponse) -> bool {
    response.headers.iter().any(|(name, value)| {
        name.eq_ignore_ascii_case("connection") && header_has_token(value.as_bytes(), b"close")
    })
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
struct CompletedIo {
    is_error: bool,
    bytes_in: usize,
    bytes_out: usize,
    elapsed: Duration,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DriveResult {
    Pending,
    RequestComplete {
        completed: CompletedIo,
        close_connection: bool,
        operation: &'static str,
    },
    ConnectionClosed,
}

struct Connection<S> {
    stream: TcpStream,
    exchange: Exchange<S>,
    continue_written: usize,
    response_written: usize,
    bytes_written: usize,
    accepted_at: Instant,
    last_activity: Instant,
    bytes_read: usize,
    metric_operation: &'static str,
    request_active: bool,
    request_started: bool,
}

impl<S> Connection<S> {
    fn new(stream: TcpStream) -> io::Result<Self> {
        stream.set_nonblocking(true)?;
        let now = Instant::now();
        Ok(Self {
            stream,
            exchange: Exchange::new(),
            continue_written: 0,
            response_written: 0,
            bytes_written: 0,
            accepted_at: now,
            last_activity: now,
            bytes_read: 0,
            metric_operation: "InvalidRequest",
            request_active: false,
            request_started: false,
        })
    }

    fn drive<H>(&mut self, now: Instant, handler: &mut H) -> io::Result<DriveResult>
    where
        H: S3Handler<Session = S>,
    {
        if !self.request_active
            && now.duration_since(self.last_activity) >= self.exchange.idle_timeout()
        {
            let _ = self.stream.shutdown(Shutdown::Both);
            self.exchange.close();
            return Ok(DriveResult::ConnectionClosed);
        }
        if self.request_active
            && now.duration_since(self.last_activity) >= self.exchange.idle_timeout()
        {
            if self.exchange.is_writing() {
                self.exchange.close();
                return Ok(DriveResult::RequestComplete {
                    completed: self.completed(Instant::now(), true),
                    close_connection: true,
                    operation: self.exchange.operation,
                });
            }
            self.exchange.timeout(handler);
        }

        if self.exchange.send_continue && !self.drive_continue()? {
            return Ok(DriveResult::Pending);
        }
        if self.exchange.is_reading() && self.drive_read(handler)? {
            return Ok(DriveResult::ConnectionClosed);
        }
        if self.exchange.send_continue && !self.drive_continue()? {
            return Ok(DriveResult::Pending);
        }
        if self.exchange.is_writing() {
            self.drive_write()
        } else {
            Ok(DriveResult::Pending)
        }
    }

    /// Returns true only when an idle peer closed without starting a request.
    fn drive_read<H>(&mut self, handler: &mut H) -> io::Result<bool>
    where
        H: S3Handler<Session = S>,
    {
        let mut scratch = [0_u8; IO_CHUNK_BYTES];
        for _ in 0..MAX_IO_STEPS_PER_TICK {
            match self.stream.read(&mut scratch) {
                Ok(0) => {
                    if self.request_active {
                        self.exchange.eof(handler);
                    } else {
                        self.exchange.close();
                        return Ok(true);
                    }
                    break;
                }
                Ok(read) => {
                    let now = Instant::now();
                    if !self.request_active {
                        self.request_active = true;
                        self.request_started = true;
                        self.accepted_at = now;
                    }
                    self.last_activity = now;
                    self.bytes_read = self.bytes_read.saturating_add(read);
                    self.exchange.ingest(handler, &scratch[..read]);
                    if self.exchange.send_continue || !self.exchange.is_reading() {
                        break;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        Ok(false)
    }

    fn drive_continue(&mut self) -> io::Result<bool> {
        while self.continue_written < CONTINUE_RESPONSE.len() {
            match self
                .stream
                .write(&CONTINUE_RESPONSE[self.continue_written..])
            {
                Ok(0) => return Ok(false),
                Ok(written) => {
                    self.continue_written += written;
                    self.bytes_written = self.bytes_written.saturating_add(written);
                    self.last_activity = Instant::now();
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => return Ok(false),
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        self.exchange.send_continue = false;
        Ok(true)
    }

    fn drive_write(&mut self) -> io::Result<DriveResult> {
        for _ in 0..MAX_IO_STEPS_PER_TICK {
            if self.response_written == self.exchange.response.len() {
                let now = Instant::now();
                let completed = self.completed(now, false);
                let close_connection = self.exchange.close_after_response;
                let operation = self.exchange.operation;
                if close_connection {
                    let _ = self.stream.shutdown(Shutdown::Both);
                    self.exchange.close();
                } else {
                    self.reset_exchange(now);
                }
                return Ok(DriveResult::RequestComplete {
                    completed,
                    close_connection,
                    operation,
                });
            }
            match self
                .stream
                .write(&self.exchange.response[self.response_written..])
            {
                Ok(0) => {
                    self.exchange.close();
                    return Ok(DriveResult::RequestComplete {
                        completed: self.completed(Instant::now(), true),
                        close_connection: true,
                        operation: self.exchange.operation,
                    });
                }
                Ok(written) => {
                    self.response_written += written;
                    self.bytes_written = self.bytes_written.saturating_add(written);
                    self.last_activity = Instant::now();
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(error) => return Err(error),
            }
        }
        Ok(DriveResult::Pending)
    }

    fn reset_exchange(&mut self, now: Instant) {
        self.exchange.reset();
        self.continue_written = 0;
        self.response_written = 0;
        self.bytes_written = 0;
        self.bytes_read = 0;
        self.last_activity = now;
    }

    fn take_request_started(&mut self) -> bool {
        std::mem::take(&mut self.request_started)
    }

    fn finish_request_cycle(&mut self) {
        self.request_active = false;
        self.metric_operation = "InvalidRequest";
    }

    fn completed(&self, now: Instant, transport_error: bool) -> CompletedIo {
        let status = self.exchange.status.unwrap_or(500);
        CompletedIo {
            is_error: transport_error || status >= 400,
            bytes_in: self.bytes_read,
            bytes_out: self.bytes_written,
            elapsed: now.duration_since(self.accepted_at),
        }
    }
}

fn protocol_error(status: u16, code: &'static str, message: &'static str) -> ServiceResponse {
    let request_id = error_request_id();
    ServiceResponse::xml(
        status,
        serialize_error(&S3ErrorResponse {
            code,
            message,
            resource: Some("/"),
            request_id: &request_id,
            host_id: Some(&request_id),
        }),
    )
    .header("x-amz-request-id", request_id.clone())
    .header("x-amz-id-2", request_id)
}

fn error_request_id() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let sequence = ERROR_REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("{timestamp:016X}{sequence:08X}")
}

fn serialize_response(response: ServiceResponse, close_connection: bool) -> Result<Vec<u8>, ()> {
    if !(100..=599).contains(&response.status) || response.body.len() as u64 > MAX_HTTP_BODY_BYTES {
        return Err(());
    }
    let mut headers = Vec::new();
    let mut semantic_empty_length = None;
    for (name, value) in response.headers {
        if name.eq_ignore_ascii_case("content-length") {
            if response.body.is_empty() && semantic_empty_length.is_none() {
                semantic_empty_length = value.parse::<u64>().ok();
            }
            continue;
        }
        if is_hop_by_hop(&name) || !valid_response_header(&name, &value) {
            continue;
        }
        if headers.len() >= MAX_RESPONSE_HEADERS {
            return Err(());
        }
        headers.push((name, value));
    }
    let content_length = if response.body.is_empty() {
        semantic_empty_length.unwrap_or(0)
    } else {
        response.body.len() as u64
    };
    let mut head = format!(
        "HTTP/1.1 {} {}\r\n",
        response.status,
        reason_phrase(response.status)
    );
    for (name, value) in headers {
        head.push_str(&name);
        head.push_str(": ");
        head.push_str(&value);
        head.push_str("\r\n");
        if head.len() > MAX_RESPONSE_HEAD_BYTES {
            return Err(());
        }
    }
    head.push_str(&format!("Content-Length: {content_length}\r\n"));
    if close_connection {
        head.push_str("Connection: close\r\n");
    }
    head.push_str("\r\n");
    if head.len() > MAX_RESPONSE_HEAD_BYTES {
        return Err(());
    }
    let mut wire = Vec::with_capacity(head.len().saturating_add(response.body.len()));
    wire.extend_from_slice(head.as_bytes());
    wire.extend_from_slice(&response.body);
    Ok(wire)
}

fn valid_response_header(name: &str, value: &str) -> bool {
    !name.is_empty()
        && name.bytes().all(is_tchar)
        && value
            .bytes()
            .all(|byte| byte == b'\t' || (byte >= 0x20 && byte != 0x7f))
}

fn is_hop_by_hop(name: &str) -> bool {
    name.eq_ignore_ascii_case("connection")
        || name.eq_ignore_ascii_case("keep-alive")
        || name.eq_ignore_ascii_case("proxy-connection")
        || name.eq_ignore_ascii_case("transfer-encoding")
        || name.eq_ignore_ascii_case("trailer")
        || name.eq_ignore_ascii_case("upgrade")
}

fn reason_phrase(status: u16) -> &'static str {
    match status {
        100 => "Continue",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        206 => "Partial Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        307 => "Temporary Redirect",
        308 => "Permanent Redirect",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        409 => "Conflict",
        411 => "Length Required",
        412 => "Precondition Failed",
        413 => "Payload Too Large",
        416 => "Range Not Satisfiable",
        417 => "Expectation Failed",
        429 => "Too Many Requests",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        _ => "Unknown",
    }
}

fn fallback_internal_response() -> Vec<u8> {
    const BODY: &[u8] = br#"<?xml version="1.0" encoding="UTF-8"?><Error><Code>InternalError</Code><Message>The pgs3 response could not be serialized.</Message></Error>"#;
    let head = format!(
        "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/xml\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        BODY.len()
    );
    let mut response = Vec::with_capacity(head.len() + BODY.len());
    response.extend_from_slice(head.as_bytes());
    response.extend_from_slice(BODY);
    response
}

fn overload_response_bytes() -> Arc<[u8]> {
    let response = protocol_error(
        503,
        "ServiceUnavailable",
        "The pgs3 HTTP worker has reached its connection limit",
    )
    .header("retry-after", "1");
    Arc::from(serialize_response(response, true).unwrap_or_else(|_| fallback_internal_response()))
}

fn track_in_flight_start(
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
    operation: &'static str,
) {
    metrics.entry(operation).or_default().begin_in_flight();
}

fn reclassify_in_flight(
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
    current: &mut &'static str,
    operation: &'static str,
) {
    if operation == *current {
        return;
    }
    metrics.entry(*current).or_default().end_in_flight();
    metrics.entry(operation).or_default().begin_in_flight();
    *current = operation;
}

fn track_operation_change<S>(
    connection: &mut Connection<S>,
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
) {
    let operation = connection.exchange.operation;
    reclassify_in_flight(metrics, &mut connection.metric_operation, operation);
}

fn track_completion(
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
    operation: &'static str,
    completed: CompletedIo,
) {
    let delta = metrics.entry(operation).or_default();
    delta.observe_completion(
        completed.is_error,
        completed.bytes_in,
        completed.bytes_out,
        completed.elapsed,
    );
    delta.end_in_flight();
}

fn track_immediate_error(
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
    operation: &'static str,
    bytes_out: usize,
    elapsed: Duration,
) {
    track_in_flight_start(metrics, operation);
    track_completion(
        metrics,
        operation,
        CompletedIo {
            is_error: true,
            bytes_in: 0,
            bytes_out,
            elapsed,
        },
    );
}

fn accept_connections<S>(
    listener: &TcpListener,
    connections: &mut Vec<Connection<S>>,
    overload_response: &Arc<[u8]>,
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
) {
    loop {
        match listener.accept() {
            Ok((stream, _peer)) if connections.len() < MAX_CONNECTIONS => {
                let accepted_at = Instant::now();
                match Connection::new(stream) {
                    Ok(connection) => connections.push(connection),
                    Err(error) => {
                        track_immediate_error(metrics, "InvalidRequest", 0, accepted_at.elapsed());
                        log!("pgs3 could not configure accepted socket: {error}");
                    }
                }
            }
            Ok((mut stream, _peer)) => {
                let accepted_at = Instant::now();
                let _ = stream.set_nonblocking(true);
                let written = stream.write(overload_response).unwrap_or(0);
                let _ = stream.shutdown(Shutdown::Both);
                track_immediate_error(
                    metrics,
                    "ServiceUnavailable",
                    written,
                    accepted_at.elapsed(),
                );
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                log!("pgs3 accept failed: {error}");
                break;
            }
        }
    }
}

fn drive_connections<H>(
    connections: &mut Vec<Connection<H::Session>>,
    handler: &mut H,
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
) where
    H: S3Handler,
{
    let now = Instant::now();
    let mut index = 0;
    while index < connections.len() {
        let outcome = catch_unwind(AssertUnwindSafe(|| connections[index].drive(now, handler)));
        let outcome = match outcome {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => {
                if connections[index].request_active {
                    let _ = catch_unwind(AssertUnwindSafe(|| {
                        connections[index].exchange.abort_session(handler)
                    }));
                    DriveResult::RequestComplete {
                        completed: connections[index].completed(Instant::now(), true),
                        close_connection: true,
                        operation: connections[index].exchange.operation,
                    }
                } else {
                    DriveResult::ConnectionClosed
                }
            }
            Err(_) => {
                if !connections[index].request_active {
                    DriveResult::ConnectionClosed
                } else if connections[index].bytes_written == 0 {
                    let _ = catch_unwind(AssertUnwindSafe(|| {
                        connections[index].exchange.abort_session(handler)
                    }));
                    connections[index].exchange.force_internal_error();
                    DriveResult::Pending
                } else {
                    let _ = catch_unwind(AssertUnwindSafe(|| {
                        connections[index].exchange.abort_session(handler)
                    }));
                    DriveResult::RequestComplete {
                        completed: connections[index].completed(Instant::now(), true),
                        close_connection: true,
                        operation: connections[index].exchange.operation,
                    }
                }
            }
        };
        if connections[index].take_request_started() {
            track_in_flight_start(metrics, "InvalidRequest");
        }
        match outcome {
            DriveResult::Pending => {
                if connections[index].request_active {
                    track_operation_change(&mut connections[index], metrics);
                }
                index += 1;
            }
            DriveResult::ConnectionClosed => {
                connections.swap_remove(index);
            }
            DriveResult::RequestComplete {
                completed,
                close_connection,
                operation,
            } => {
                reclassify_in_flight(metrics, &mut connections[index].metric_operation, operation);
                track_completion(metrics, connections[index].metric_operation, completed);
                if close_connection {
                    connections.swap_remove(index);
                } else {
                    connections[index].finish_request_cycle();
                    index += 1;
                }
            }
        }
    }
}

fn abandon_connections<H>(
    connections: &mut Vec<Connection<H::Session>>,
    handler: &mut H,
    metrics: &mut BTreeMap<&'static str, MetricDelta>,
) where
    H: S3Handler,
{
    for mut connection in connections.drain(..) {
        if connection.take_request_started() {
            track_in_flight_start(metrics, "InvalidRequest");
        }
        if !connection.request_active {
            continue;
        }
        let _ = catch_unwind(AssertUnwindSafe(|| {
            connection.exchange.abort_session(handler)
        }));
        track_operation_change(&mut connection, metrics);
        let completed = connection.completed(Instant::now(), true);
        track_completion(metrics, connection.metric_operation, completed);
    }
}

fn flush_metrics(metrics: &mut BTreeMap<&'static str, MetricDelta>, slot: i32) -> bool {
    let mut success = true;
    metrics.retain(|operation, delta| {
        if super::add_worker_metric("http", slot, operation, *delta) {
            false
        } else {
            success = false;
            true
        }
    });
    success
}

fn wait_for_events<S>(listener: &TcpListener, connections: &[Connection<S>]) -> bool {
    #[cfg(unix)]
    {
        use std::os::fd::AsRawFd;

        struct WaitSetGuard(*mut pg_sys::WaitEventSet);
        impl Drop for WaitSetGuard {
            fn drop(&mut self) {
                unsafe {
                    pg_sys::FreeWaitEventSet(self.0);
                }
            }
        }

        unsafe {
            pg_sys::ResetLatch(pg_sys::MyLatch);
            let capacity = i32::try_from(connections.len().saturating_add(3))
                .expect("connection limit fits WaitEventSet capacity");
            let set = pg_sys::CreateWaitEventSet(pg_sys::CurrentResourceOwner, capacity);
            let _guard = WaitSetGuard(set);
            pg_sys::AddWaitEventToSet(
                set,
                pg_sys::WL_LATCH_SET,
                pg_sys::PGINVALID_SOCKET,
                pg_sys::MyLatch,
                std::ptr::null_mut(),
            );
            pg_sys::AddWaitEventToSet(
                set,
                pg_sys::WL_POSTMASTER_DEATH,
                pg_sys::PGINVALID_SOCKET,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            );
            pg_sys::AddWaitEventToSet(
                set,
                pg_sys::WL_SOCKET_READABLE,
                listener.as_raw_fd(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            );
            for connection in connections {
                let events =
                    if connection.exchange.send_continue || connection.exchange.is_writing() {
                        pg_sys::WL_SOCKET_WRITEABLE
                    } else {
                        pg_sys::WL_SOCKET_READABLE
                    };
                pg_sys::AddWaitEventToSet(
                    set,
                    events,
                    connection.stream.as_raw_fd(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                );
            }
            let mut occurred = pg_sys::WaitEvent::default();
            let count = pg_sys::WaitEventSetWait(
                set,
                REACTOR_MAX_SLEEP.as_millis() as _,
                &mut occurred,
                1,
                pg_sys::PG_WAIT_EXTENSION,
            );
            if count > 0 && occurred.events & pg_sys::WL_POSTMASTER_DEATH != 0 {
                return false;
            }
        }
        !BackgroundWorker::sigterm_received()
    }
    #[cfg(not(unix))]
    {
        let _ = (listener, connections);
        BackgroundWorker::wait_latch(Some(REACTOR_MAX_SLEEP))
    }
}

fn record_state(
    slot: i32,
    launcher_pid: i32,
    status: &str,
    bind: Option<&BindConfig>,
    error: Option<&str>,
) {
    let listen_addr = bind.map(|config| config.address.to_string());
    let _ = super::set_worker_state(WorkerState {
        kind: "http",
        slot,
        launcher_pid,
        status,
        listen_addr: listen_addr.as_deref(),
        port: bind.map(|config| i32::from(config.port)),
        error,
    });
}

#[pg_guard]
#[unsafe(no_mangle)]
pub extern "C-unwind" fn pgs3_http_main(argument: pg_sys::Datum) {
    BackgroundWorker::attach_signal_handlers(SignalWakeFlags::SIGHUP | SignalWakeFlags::SIGTERM);
    let (launcher_pid, slot) = unpack_child_argument(argument);
    let database = BackgroundWorker::get_extra().to_owned();
    let server_role = crate::config::server_role();
    if let Err(error) = super::connect_worker_to_spi_as_service(&database, &server_role) {
        warning!("pgs3 HTTP worker could not connect: {error}");
        return;
    }
    if !super::runtime_schema_ready() {
        warning!("pgs3 HTTP worker found no runtime schema in {database}");
        return;
    }

    let mut bind_config = match BindConfig::load() {
        Ok(config) => config,
        Err(error) => {
            record_state(slot, launcher_pid, "error", None, Some(&error));
            warning!("{error}");
            return;
        }
    };
    let mut listener = match bind_reuse_port(&bind_config) {
        Ok(listener) => listener,
        Err(error) => {
            let message = format!(
                "could not bind {}:{} with SO_REUSEPORT: {error}",
                bind_config.address, bind_config.port
            );
            record_state(
                slot,
                launcher_pid,
                "error",
                Some(&bind_config),
                Some(&message),
            );
            warning!("{message}");
            return;
        }
    };

    let overload_response = overload_response_bytes();
    let mut service = PgS3Service::for_worker();
    let mut connections = Vec::with_capacity(32);
    let mut metrics = BTreeMap::new();
    let mut next_heartbeat = Instant::now();
    record_state(slot, launcher_pid, "running", Some(&bind_config), None);
    log!(
        "pgs3 HTTP worker {slot} listening on {}:{} as {}",
        bind_config.address,
        bind_config.port,
        server_role
    );

    loop {
        if BackgroundWorker::sighup_received() {
            service = rebuild_after_reload(super::reload_configuration, PgS3Service::for_worker);
            // BodySession carries only owned request metadata, digests, and
            // durable upload identifiers: it holds no SPI borrow or open
            // transaction. Already accepted uploads can therefore safely use
            // the rebuilt service. PgDatabase also reads the timeout GUC in
            // every short transaction, so no stale Rust snapshot survives.
            match BindConfig::load() {
                Ok(new_config) if new_config != bind_config => match bind_reuse_port(&new_config) {
                    Ok(new_listener) => {
                        listener = new_listener;
                        bind_config = new_config;
                        record_state(slot, launcher_pid, "running", Some(&bind_config), None);
                        log!(
                            "pgs3 HTTP worker {slot} rebound to {}:{}",
                            bind_config.address,
                            bind_config.port
                        );
                    }
                    Err(error) => {
                        let message =
                            format!("SIGHUP rebind failed; retaining old socket: {error}");
                        record_state(
                            slot,
                            launcher_pid,
                            "error",
                            Some(&bind_config),
                            Some(&message),
                        );
                        warning!("{message}");
                    }
                },
                Ok(_) => {}
                Err(error) => {
                    record_state(
                        slot,
                        launcher_pid,
                        "error",
                        Some(&bind_config),
                        Some(&error),
                    );
                    warning!("{error}");
                }
            }
        }

        accept_connections(
            &listener,
            &mut connections,
            &overload_response,
            &mut metrics,
        );
        drive_connections(&mut connections, &mut service, &mut metrics);

        if Instant::now() >= next_heartbeat {
            if !flush_metrics(&mut metrics, slot) {
                warning!("pgs3 HTTP worker {slot} could not flush metrics");
            }
            record_state(slot, launcher_pid, "running", Some(&bind_config), None);
            next_heartbeat = Instant::now() + HEARTBEAT_INTERVAL;
        }
        if !wait_for_events(&listener, &connections) {
            break;
        }
    }

    // Pending uploads are crash/termination safe and GC owns eventual cleanup.
    // Abort request sessions and close their gauges before dropping sockets so
    // graceful SIGTERM cannot leave a materialized in-flight count behind.
    abandon_connections(&mut connections, &mut service, &mut metrics);
    let _ = flush_metrics(&mut metrics, slot);
    record_state(slot, launcher_pid, "stopped", Some(&bind_config), None);
    log!("pgs3 HTTP worker {slot} exiting");
}

#[cfg(target_os = "linux")]
fn bind_reuse_port(config: &BindConfig) -> io::Result<TcpListener> {
    use std::ffi::c_void;
    use std::mem::{forget, size_of};
    use std::os::fd::FromRawFd;

    const AF_INET: i32 = 2;
    const AF_INET6: i32 = 10;
    const SOCK_STREAM: i32 = 1;
    const SOL_SOCKET: i32 = 1;
    const SO_REUSEADDR: i32 = 2;
    const SO_REUSEPORT: i32 = 15;
    const IPPROTO_IPV6: i32 = 41;
    const IPV6_V6ONLY: i32 = 26;

    unsafe extern "C" {
        #[link_name = "socket"]
        fn c_socket(domain: i32, socket_type: i32, protocol: i32) -> i32;
        #[link_name = "setsockopt"]
        fn c_setsockopt(
            socket: i32,
            level: i32,
            option_name: i32,
            option_value: *const c_void,
            option_len: u32,
        ) -> i32;
        #[link_name = "bind"]
        fn c_bind(socket: i32, address: *const c_void, address_len: u32) -> i32;
        #[link_name = "listen"]
        fn c_listen(socket: i32, backlog: i32) -> i32;
        #[link_name = "close"]
        fn c_close(fd: i32) -> i32;
    }

    #[repr(C)]
    struct SockAddrIn {
        family: u16,
        port: u16,
        address: [u8; 4],
        zero: [u8; 8],
    }

    #[repr(C)]
    struct SockAddrIn6 {
        family: u16,
        port: u16,
        flow_info: u32,
        address: [u8; 16],
        scope_id: u32,
    }

    struct FdGuard(i32);
    impl Drop for FdGuard {
        fn drop(&mut self) {
            unsafe {
                c_close(self.0);
            }
        }
    }

    let family = match config.address {
        IpAddr::V4(_) => AF_INET,
        IpAddr::V6(_) => AF_INET6,
    };
    let fd = unsafe { c_socket(family, SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let guard = FdGuard(fd);
    let one = 1_i32;
    let set_option = |level, name| {
        let result = unsafe {
            c_setsockopt(
                fd,
                level,
                name,
                (&one as *const i32).cast(),
                size_of::<i32>() as u32,
            )
        };
        if result == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    };
    set_option(SOL_SOCKET, SO_REUSEADDR)?;
    set_option(SOL_SOCKET, SO_REUSEPORT)?;
    if matches!(config.address, IpAddr::V6(_)) {
        set_option(IPPROTO_IPV6, IPV6_V6ONLY)?;
    }

    let bind_result = match config.address {
        IpAddr::V4(address) => {
            let address = SockAddrIn {
                family: AF_INET as u16,
                port: config.port.to_be(),
                address: address.octets(),
                zero: [0; 8],
            };
            unsafe {
                c_bind(
                    fd,
                    (&address as *const SockAddrIn).cast(),
                    size_of::<SockAddrIn>() as u32,
                )
            }
        }
        IpAddr::V6(address) => {
            let address = SockAddrIn6 {
                family: AF_INET6 as u16,
                port: config.port.to_be(),
                flow_info: 0,
                address: address.octets(),
                scope_id: 0,
            };
            unsafe {
                c_bind(
                    fd,
                    (&address as *const SockAddrIn6).cast(),
                    size_of::<SockAddrIn6>() as u32,
                )
            }
        }
    };
    if bind_result != 0 {
        return Err(io::Error::last_os_error());
    }
    if unsafe { c_listen(fd, MAX_CONNECTIONS as i32) } != 0 {
        return Err(io::Error::last_os_error());
    }

    let listener = unsafe { TcpListener::from_raw_fd(fd) };
    forget(guard);
    listener.set_nonblocking(true)?;
    Ok(listener)
}

#[cfg(not(target_os = "linux"))]
fn bind_reuse_port(_config: &BindConfig) -> io::Result<TcpListener> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "SO_REUSEPORT HTTP workers are currently supported on Linux only",
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeHandler {
        pushed: Vec<u8>,
        push_addresses: Vec<usize>,
        finished: usize,
        aborted: usize,
        panic_on_push: bool,
        immediate: bool,
    }

    impl S3Handler for FakeHandler {
        type Session = ();

        fn operation_name(&self, _request: &RequestHead) -> &'static str {
            "PutObject"
        }

        fn handle_head(&mut self, _request: RequestHead) -> HandlerOutcome<Self::Session> {
            if self.immediate {
                HandlerOutcome::Immediate(ServiceResponse::empty(403))
            } else {
                HandlerOutcome::ReceiveBody(())
            }
        }

        fn push_body(
            &mut self,
            _session: &mut Self::Session,
            bytes: &[u8],
        ) -> Result<(), ServiceResponse> {
            assert!(!self.panic_on_push, "synthetic handler panic");
            self.push_addresses.push(bytes.as_ptr() as usize);
            self.pushed.extend_from_slice(bytes);
            Ok(())
        }

        fn finish_body(&mut self, _session: &mut Self::Session) -> ServiceResponse {
            self.finished += 1;
            ServiceResponse::xml(200, self.pushed.clone())
        }

        fn abort_body(&mut self, _session: &mut Self::Session) {
            self.aborted += 1;
        }
    }

    fn wire_body(exchange: &Exchange<()>) -> &[u8] {
        let offset = exchange
            .response
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .unwrap()
            + 4;
        &exchange.response[offset..]
    }

    fn response_has_close(exchange: &Exchange<()>) -> bool {
        exchange
            .response
            .windows(b"\r\nConnection: close\r\n".len())
            .any(|window| window == b"\r\nConnection: close\r\n")
    }

    fn read_response(stream: &mut TcpStream) -> Vec<u8> {
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .unwrap();
        let mut response = Vec::new();
        loop {
            if let Some(head_end) = response.windows(4).position(|window| window == b"\r\n\r\n") {
                let head_end = head_end + 4;
                let head = std::str::from_utf8(&response[..head_end]).unwrap();
                let length = head
                    .lines()
                    .find_map(|line| {
                        line.strip_prefix("Content-Length: ")
                            .and_then(|value| value.trim().parse::<usize>().ok())
                    })
                    .unwrap();
                if response.len() >= head_end + length {
                    response.truncate(head_end + length);
                    return response;
                }
            }
            let mut block = [0_u8; 4096];
            let read = stream.read(&mut block).unwrap();
            assert!(read > 0, "connection closed before one response completed");
            response.extend_from_slice(&block[..read]);
        }
    }

    #[test]
    fn sighup_rebuild_reads_the_reloaded_setting() {
        let setting = std::cell::Cell::new(5_000);
        let order = std::cell::RefCell::new(Vec::new());

        let service_timeout = rebuild_after_reload(
            || {
                order.borrow_mut().push("reload");
                setting.set(250);
            },
            || {
                order.borrow_mut().push("rebuild");
                setting.get()
            },
        );

        assert_eq!(service_timeout, 250);
        assert_eq!(*order.borrow(), ["reload", "rebuild"]);
    }

    #[test]
    fn metric_lifecycle_reclassifies_and_balances_in_flight() {
        let mut metrics = BTreeMap::new();
        let mut operation = "InvalidRequest";
        track_in_flight_start(&mut metrics, operation);
        reclassify_in_flight(&mut metrics, &mut operation, "PutObject");
        track_completion(
            &mut metrics,
            operation,
            CompletedIo {
                is_error: false,
                bytes_in: 31,
                bytes_out: 47,
                elapsed: Duration::from_micros(2_500),
            },
        );

        assert_eq!(operation, "PutObject");
        assert_eq!(metrics.len(), 2);
        assert_eq!(metrics["InvalidRequest"].in_flight_delta, 0);
        let completed = metrics["PutObject"];
        assert_eq!(completed.in_flight_delta, 0);
        assert_eq!(completed.requests, 1);
        assert_eq!(completed.errors, 0);
        assert_eq!(completed.bytes_in, 31);
        assert_eq!(completed.bytes_out, 47);
        assert_eq!(completed.latency_le_1ms, 0);
        assert_eq!(completed.latency_le_5ms, 1);
    }

    #[test]
    fn transport_failure_is_an_error_and_releases_gauge() {
        let mut metrics = BTreeMap::new();
        track_in_flight_start(&mut metrics, "GetObject");
        track_completion(
            &mut metrics,
            "GetObject",
            CompletedIo {
                is_error: true,
                bytes_in: 19,
                bytes_out: 0,
                elapsed: Duration::from_millis(11),
            },
        );

        let completed = metrics["GetObject"];
        assert_eq!(completed.in_flight_delta, 0);
        assert_eq!(completed.requests, 1);
        assert_eq!(completed.errors, 1);
        assert_eq!(completed.latency_le_10ms, 0);
        assert_eq!(completed.latency_le_50ms, 1);
    }

    #[test]
    fn fragmented_head_and_head_body_same_packet_are_preserved() {
        let mut exchange = Exchange::new();
        let mut handler = FakeHandler::default();
        exchange.ingest(
            &mut handler,
            b"PUT /bucket/key HTTP/1.1\r\nHost: local\r\nContent-Len",
        );
        assert!(exchange.is_reading());
        exchange.ingest(&mut handler, b"gth: 3\r\n\r\nabc");
        assert_eq!(handler.pushed, b"abc");
        assert_eq!(handler.finished, 1);
        assert_eq!(wire_body(&exchange), b"abc");
        assert_eq!(exchange.operation, "PutObject");
    }

    #[test]
    fn content_length_exact_short_and_extra_are_unambiguous() {
        let mut exact = Exchange::new();
        let mut handler = FakeHandler::default();
        exact.ingest(
            &mut handler,
            b"PUT /b/k HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabc",
        );
        assert_eq!(handler.pushed, b"abc");
        assert_eq!(exact.status, Some(200));

        let mut short = Exchange::new();
        let mut handler = FakeHandler::default();
        short.ingest(
            &mut handler,
            b"PUT /b/k HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nab",
        );
        short.eof(&mut handler);
        assert_eq!(handler.aborted, 1);
        assert_eq!(short.status, Some(400));

        let mut extra = Exchange::new();
        let mut handler = FakeHandler::default();
        extra.ingest(
            &mut handler,
            b"PUT /b/k HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\nabcNEXT",
        );
        assert_eq!(handler.pushed, b"abc");
        assert_eq!(handler.finished, 1);
        assert_eq!(extra.status, Some(200));
        assert!(extra.close_after_response);
        assert!(response_has_close(&extra));
    }

    #[test]
    fn content_length_body_is_borrowed_directly_by_the_handler() {
        let mut exchange = Exchange::new();
        let mut handler = FakeHandler::default();
        exchange.ingest(
            &mut handler,
            b"PUT /b/k HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\n\r\n",
        );
        let body_and_pipeline = b"abcNEXT";
        let body_address = body_and_pipeline.as_ptr() as usize;
        exchange.ingest(&mut handler, body_and_pipeline);

        assert_eq!(handler.pushed, b"abc");
        assert_eq!(handler.push_addresses, [body_address]);
        assert_eq!(handler.finished, 1);
        assert!(exchange.close_after_response);
    }

    #[test]
    fn coalesced_next_request_is_not_reparsed_and_forces_close() {
        let mut exchange = Exchange::new();
        let mut handler = FakeHandler::default();
        exchange.ingest(
            &mut handler,
            b"GET /first HTTP/1.1\r\nHost: x\r\n\r\nGET /second HTTP/1.1\r\nHost: x\r\n\r\n",
        );
        assert_eq!(handler.finished, 1);
        assert_eq!(exchange.status, Some(200));
        assert!(exchange.close_after_response);
        assert!(response_has_close(&exchange));
    }

    #[test]
    fn http_10_and_explicit_close_never_enter_keep_alive() {
        let mut old = Exchange::new();
        let mut handler = FakeHandler::default();
        old.ingest(&mut handler, b"GET /b/k HTTP/1.0\r\nHost: x\r\n\r\n");
        assert_eq!(old.status, Some(400));
        assert!(response_has_close(&old));

        let mut explicit = Exchange::new();
        let mut handler = FakeHandler::default();
        explicit.ingest(
            &mut handler,
            b"GET /b/k HTTP/1.1\r\nHost: x\r\nConnection: keep-alive, close\r\n\r\n",
        );
        assert_eq!(explicit.status, Some(200));
        assert!(explicit.close_after_response);
        assert!(response_has_close(&explicit));

        let mut persistent = Exchange::new();
        let mut handler = FakeHandler::default();
        persistent.ingest(&mut handler, b"GET /b/k HTTP/1.1\r\nHost: x\r\n\r\n");
        assert_eq!(persistent.status, Some(200));
        assert!(!persistent.close_after_response);
        assert!(!response_has_close(&persistent));
    }

    #[test]
    fn server_close_response_header_is_honored_but_not_forwarded_twice() {
        let mut exchange = Exchange::<()>::new();
        exchange.queue_response(ServiceResponse {
            status: 200,
            headers: vec![("connection".into(), "keep-alive, close".into())],
            body: Vec::new(),
        });
        assert!(exchange.close_after_response);
        assert!(response_has_close(&exchange));
        assert_eq!(
            exchange
                .response
                .windows(b"Connection: close".len())
                .filter(|window| *window == b"Connection: close")
                .count(),
            1
        );
    }

    #[test]
    fn one_socket_serves_two_sequential_requests_and_balances_metrics() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        let mut connections = vec![Connection::new(server).unwrap()];
        let mut handler = FakeHandler::default();
        let mut metrics = BTreeMap::new();

        client
            .write_all(b"GET /first HTTP/1.1\r\nHost: x\r\n\r\n")
            .unwrap();
        for _ in 0..1000 {
            drive_connections(&mut connections, &mut handler, &mut metrics);
            if metrics
                .get("PutObject")
                .is_some_and(|delta| delta.requests == 1)
            {
                break;
            }
            std::thread::yield_now();
        }
        let first = read_response(&mut client);
        assert!(
            !first
                .windows(b"Connection: close".len())
                .any(|window| window == b"Connection: close")
        );
        assert_eq!(connections.len(), 1);
        assert!(!connections[0].request_active);
        assert_eq!(metrics["PutObject"].requests, 1);
        assert_eq!(metrics["PutObject"].in_flight_delta, 0);
        assert_eq!(metrics["InvalidRequest"].in_flight_delta, 0);

        client
            .write_all(b"GET /second HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
            .unwrap();
        for _ in 0..1000 {
            drive_connections(&mut connections, &mut handler, &mut metrics);
            if connections.is_empty() {
                break;
            }
            std::thread::yield_now();
        }
        let second = read_response(&mut client);
        assert!(
            second
                .windows(b"Connection: close".len())
                .any(|window| window == b"Connection: close")
        );
        assert!(connections.is_empty());
        assert_eq!(handler.finished, 2);
        assert_eq!(metrics["PutObject"].requests, 2);
        assert_eq!(metrics["PutObject"].in_flight_delta, 0);
        assert_eq!(metrics["InvalidRequest"].in_flight_delta, 0);
    }

    #[test]
    fn idle_peer_close_does_not_create_a_request_metric() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        let (server, _) = listener.accept().unwrap();
        let mut connections = vec![Connection::new(server).unwrap()];
        let mut handler = FakeHandler::default();
        let mut metrics = BTreeMap::new();
        drop(client);

        for _ in 0..1000 {
            drive_connections(&mut connections, &mut handler, &mut metrics);
            if connections.is_empty() {
                break;
            }
            std::thread::yield_now();
        }
        assert!(connections.is_empty());
        assert!(metrics.is_empty());
        assert_eq!(handler.finished, 0);
        assert_eq!(handler.aborted, 0);
    }

    #[test]
    fn transport_chunked_accepts_splits_extensions_and_trailers() {
        let entity = b"4;foo=bar\r\nWiki\r\n5; quoted=\"a;b\"\r\npedia\r\n0\r\nX-Hash: ok\r\n\r\n";
        let mut decoder = HttpChunkedDecoder::new();
        let mut body = Vec::new();
        for byte in entity {
            let mut decoded = Vec::new();
            decoder.push(&[*byte], &mut decoded).unwrap();
            body.extend_from_slice(&decoded);
        }
        assert_eq!(body, b"Wikipedia");
        assert!(decoder.is_complete());

        let mut decoder = HttpChunkedDecoder::new();
        let mut decoded = Vec::new();
        let mut with_pipeline = entity.to_vec();
        with_pipeline.extend_from_slice(b"NEXT");
        let progress = decoder.push(&with_pipeline, &mut decoded).unwrap();
        assert_eq!(progress.consumed, entity.len());
        assert!(progress.complete);
        assert_eq!(decoded, b"Wikipedia");
    }

    #[test]
    fn transport_chunked_rejects_invalid_and_incomplete_framing() {
        let mut decoder = HttpChunkedDecoder::new();
        assert_eq!(
            decoder.push(b"z\r\n", &mut Vec::new()).unwrap_err(),
            FramingError::InvalidChunk
        );
        let mut decoder = HttpChunkedDecoder::new();
        assert_eq!(
            decoder.push(b"1\r\naX", &mut Vec::new()).unwrap_err(),
            FramingError::InvalidChunk
        );
        let mut decoder = HttpChunkedDecoder::new();
        assert_eq!(
            decoder
                .push(b"0\r\n folded: no\r\n\r\n", &mut Vec::new())
                .unwrap_err(),
            FramingError::InvalidTrailer
        );
        let mut framing = BodyFraming::Chunked(HttpChunkedDecoder::new());
        let (_, decoded) = framing.push(b"2\r\na").unwrap();
        assert!(matches!(decoded, Cow::Owned(_)));
        assert!(!framing.is_complete());
    }

    #[test]
    fn no_body_finishes_immediately() {
        let mut exchange = Exchange::new();
        let mut handler = FakeHandler::default();
        exchange.ingest(&mut handler, b"GET /b/k HTTP/1.1\r\nHost: x\r\n\r\n");
        assert!(handler.pushed.is_empty());
        assert_eq!(handler.finished, 1);
        assert_eq!(exchange.status, Some(200));
    }

    #[test]
    fn expect_continue_only_follows_successful_prepare() {
        let head =
            b"PUT /b/k HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nExpect: 100-continue\r\n\r\n";
        let mut exchange = Exchange::new();
        let mut handler = FakeHandler::default();
        exchange.ingest(&mut handler, head);
        assert!(exchange.send_continue);
        assert!(exchange.is_reading());

        let mut rejected = Exchange::new();
        let mut handler = FakeHandler {
            immediate: true,
            ..FakeHandler::default()
        };
        rejected.ingest(&mut handler, head);
        assert!(!rejected.send_continue);
        assert_eq!(rejected.status, Some(403));

        let mut unsupported = Exchange::new();
        let mut handler = FakeHandler::default();
        unsupported.ingest(
            &mut handler,
            b"PUT /b/k HTTP/1.1\r\nHost: x\r\nExpect: magic\r\n\r\n",
        );
        assert_eq!(unsupported.status, Some(417));
    }

    #[test]
    fn invalid_chunk_aborts_session_and_returns_bounded_xml() {
        let mut exchange = Exchange::new();
        let mut handler = FakeHandler::default();
        exchange.ingest(
            &mut handler,
            b"PUT /b/k HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\nq\r\n",
        );
        assert_eq!(handler.aborted, 1);
        assert_eq!(exchange.status, Some(400));
        assert!(exchange.response.len() < MAX_RESPONSE_HEAD_BYTES + 1024);
        assert!(wire_body(&exchange).starts_with(b"<?xml"));
    }

    #[test]
    fn panic_leaves_session_available_for_abort_and_worker_error() {
        let mut exchange = Exchange::new();
        let mut handler = FakeHandler {
            panic_on_push: true,
            ..FakeHandler::default()
        };
        let panic = catch_unwind(AssertUnwindSafe(|| {
            exchange.ingest(
                &mut handler,
                b"PUT /b/k HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\n\r\nx",
            )
        }));
        assert!(panic.is_err());
        exchange.abort_session(&mut handler);
        exchange.force_internal_error();
        assert_eq!(handler.aborted, 1);
        assert_eq!(exchange.status, Some(500));
    }

    #[test]
    fn response_serializer_filters_injection_and_owns_framing() {
        let response = ServiceResponse {
            status: 200,
            headers: vec![
                ("x-safe".into(), "yes".into()),
                ("x-bad\r\ninjected".into(), "no".into()),
                ("x-value".into(), "ok\r\nInjected: yes".into()),
                ("Connection".into(), "keep-alive".into()),
                ("Content-Length".into(), "999".into()),
            ],
            body: b"abc".to_vec(),
        };
        let wire = String::from_utf8(serialize_response(response, true).unwrap()).unwrap();
        assert!(wire.starts_with("HTTP/1.1 200 OK\r\n"));
        assert!(wire.contains("x-safe: yes\r\n"));
        assert!(!wire.contains("injected"));
        assert!(!wire.contains("Injected"));
        assert!(wire.contains("Content-Length: 3\r\n"));
        assert!(wire.contains("Connection: close\r\n"));
        assert!(wire.ends_with("\r\n\r\nabc"));
    }

    #[test]
    fn empty_response_preserves_head_semantic_length() {
        let response = ServiceResponse {
            status: 200,
            headers: vec![("content-length".into(), "123".into())],
            body: Vec::new(),
        };
        let wire = String::from_utf8(serialize_response(response, false).unwrap()).unwrap();
        assert!(wire.contains("Content-Length: 123\r\n"));
        assert!(!wire.contains("Connection: close\r\n"));
        assert!(wire.ends_with("\r\n\r\n"));
    }

    #[test]
    fn overload_response_is_bounded_and_close_delimited() {
        let response = overload_response_bytes();
        assert!(response.len() < 4096);
        let response = std::str::from_utf8(&response).unwrap();
        assert!(response.starts_with("HTTP/1.1 503 Service Unavailable\r\n"));
        assert!(response.contains("Connection: close\r\n"));
    }
}
