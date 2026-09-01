//! Bounded HTTP/1.1 request-head and path-style S3 target parsing.

use std::fmt;

/// Limits applied before an HTTP request is handed to authentication code.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HeadLimits {
    pub max_head_bytes: usize,
    pub max_request_line_bytes: usize,
    pub max_header_line_bytes: usize,
    pub max_headers: usize,
}

impl Default for HeadLimits {
    fn default() -> Self {
        Self {
            max_head_bytes: 64 * 1024,
            max_request_line_bytes: 8 * 1024,
            max_header_line_bytes: 16 * 1024,
            max_headers: 100,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum HttpParseError {
    HeadTooLarge,
    RequestLineTooLarge,
    HeaderLineTooLarge,
    TooManyHeaders,
    InvalidRequestLine,
    UnsupportedHttpVersion,
    InvalidRequestTarget,
    InvalidHeaderName,
    InvalidHeaderValue,
    DuplicateHost,
    MissingHost,
    InvalidContentLength,
    AmbiguousBodyFraming,
    UnsupportedTransferEncoding,
    ParserAlreadyCompleted,
    InvalidPercentEncoding,
    InvalidUtf8Path,
    InvalidBucket,
    NulInPath,
}

impl fmt::Display for HttpParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}",
            match self {
                Self::HeadTooLarge => "HTTP request head exceeds its size limit",
                Self::RequestLineTooLarge => "HTTP request line exceeds its size limit",
                Self::HeaderLineTooLarge => "HTTP header line exceeds its size limit",
                Self::TooManyHeaders => "HTTP request has too many headers",
                Self::InvalidRequestLine => "invalid HTTP request line",
                Self::UnsupportedHttpVersion => "only HTTP/1.1 is supported",
                Self::InvalidRequestTarget => "invalid origin-form HTTP request target",
                Self::InvalidHeaderName => "invalid HTTP header name",
                Self::InvalidHeaderValue => "invalid HTTP header value",
                Self::DuplicateHost => "multiple Host headers are not accepted",
                Self::MissingHost => "HTTP/1.1 request is missing Host",
                Self::InvalidContentLength => "invalid or duplicate Content-Length",
                Self::AmbiguousBodyFraming =>
                    "both Transfer-Encoding and Content-Length were supplied",
                Self::UnsupportedTransferEncoding => "unsupported Transfer-Encoding",
                Self::ParserAlreadyCompleted => "HTTP request-head parser was already completed",
                Self::InvalidPercentEncoding => "invalid percent escape in request target",
                Self::InvalidUtf8Path => "path-style bucket or key is not valid UTF-8",
                Self::InvalidBucket => "invalid path-style bucket component",
                Self::NulInPath => "NUL is not representable in a PostgreSQL text key",
            }
        )
    }
}

impl std::error::Error for HttpParseError {}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Header {
    /// Always lowercase ASCII.
    pub name: String,
    /// Original field value with leading/trailing optional whitespace removed.
    pub value: Vec<u8>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct HeaderMap {
    fields: Vec<Header>,
}

impl HeaderMap {
    #[must_use]
    pub fn fields(&self) -> &[Header] {
        &self.fields
    }

    #[must_use]
    pub fn get(&self, name: &str) -> Option<&[u8]> {
        self.fields
            .iter()
            .find(|field| field.name.eq_ignore_ascii_case(name))
            .map(|field| field.value.as_slice())
    }

    #[allow(dead_code)]
    pub fn get_str(&self, name: &str) -> Result<Option<&str>, std::str::Utf8Error> {
        self.get(name).map(std::str::from_utf8).transpose()
    }

    pub fn get_all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a [u8]> + 'a {
        self.fields
            .iter()
            .filter(move |field| field.name.eq_ignore_ascii_case(name))
            .map(|field| field.value.as_slice())
    }

    /// Constructs a validated map for tests and non-socket callers.
    pub fn from_pairs<I, N, V>(pairs: I) -> Result<Self, HttpParseError>
    where
        I: IntoIterator<Item = (N, V)>,
        N: AsRef<str>,
        V: AsRef<[u8]>,
    {
        let mut fields = Vec::new();
        for (name, value) in pairs {
            let name = name.as_ref().as_bytes();
            if name.is_empty() || !name.iter().copied().all(is_tchar) {
                return Err(HttpParseError::InvalidHeaderName);
            }
            let value = trim_ows(value.as_ref());
            if !valid_field_value(value) {
                return Err(HttpParseError::InvalidHeaderValue);
            }
            fields.push(Header {
                name: String::from_utf8(name.to_ascii_lowercase())
                    .expect("HTTP token names are ASCII"),
                value: value.to_vec(),
            });
        }
        Ok(Self { fields })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct QueryParam {
    pub raw_name: String,
    pub raw_value: String,
    pub name: Vec<u8>,
    pub value: Vec<u8>,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct QueryParams {
    pairs: Vec<QueryParam>,
}

impl QueryParams {
    pub fn parse(raw: &str) -> Result<Self, HttpParseError> {
        let mut pairs = Vec::new();
        if raw.is_empty() {
            return Ok(Self { pairs });
        }
        for component in raw.split('&') {
            let (raw_name, raw_value) = component.split_once('=').unwrap_or((component, ""));
            pairs.push(QueryParam {
                raw_name: raw_name.to_owned(),
                raw_value: raw_value.to_owned(),
                // SigV4 follows RFC 3986: unlike form encoding, '+' is literal.
                name: percent_decode(raw_name.as_bytes())?,
                value: percent_decode(raw_value.as_bytes())?,
            });
        }
        Ok(Self { pairs })
    }

    #[must_use]
    pub fn pairs(&self) -> &[QueryParam] {
        &self.pairs
    }

    pub fn get(&self, name: &str) -> Option<&[u8]> {
        self.pairs
            .iter()
            .find(|pair| pair.name == name.as_bytes())
            .map(|pair| pair.value.as_slice())
    }

    #[allow(dead_code)]
    pub fn get_str(&self, name: &str) -> Result<Option<&str>, std::str::Utf8Error> {
        self.get(name).map(std::str::from_utf8).transpose()
    }

    pub fn get_all<'a>(&'a self, name: &'a str) -> impl Iterator<Item = &'a [u8]> + 'a {
        self.pairs
            .iter()
            .filter(move |pair| pair.name == name.as_bytes())
            .map(|pair| pair.value.as_slice())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestTarget {
    pub raw_path: String,
    pub raw_query: Option<String>,
    pub query: QueryParams,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RequestHead {
    pub method: String,
    pub target: RequestTarget,
    pub headers: HeaderMap,
    pub content_length: Option<u64>,
    pub transfer_chunked: bool,
}

/// Incrementally collects exactly one HTTP request head and retains any bytes
/// already read from its body.
#[derive(Debug)]
pub struct RequestHeadParser {
    limits: HeadLimits,
    buffer: Vec<u8>,
    remainder: Vec<u8>,
    completed: bool,
}

impl RequestHeadParser {
    #[must_use]
    pub fn new(limits: HeadLimits) -> Self {
        Self {
            limits,
            buffer: Vec::new(),
            remainder: Vec::new(),
            completed: false,
        }
    }

    pub fn push(&mut self, bytes: &[u8]) -> Result<Option<RequestHead>, HttpParseError> {
        if self.completed {
            return Err(HttpParseError::ParserAlreadyCompleted);
        }
        self.buffer.extend_from_slice(bytes);

        let Some(end) = find_subslice(&self.buffer, b"\r\n\r\n") else {
            if self.buffer.len() > self.limits.max_head_bytes {
                return Err(HttpParseError::HeadTooLarge);
            }
            return Ok(None);
        };
        let head_end = end + 4;
        if head_end > self.limits.max_head_bytes {
            return Err(HttpParseError::HeadTooLarge);
        }

        let request = parse_complete_head(&self.buffer[..end], self.limits)?;
        self.remainder.extend_from_slice(&self.buffer[head_end..]);
        self.buffer.clear();
        self.completed = true;
        Ok(Some(request))
    }

    #[must_use]
    pub fn take_remainder(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.remainder)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct PathStyleTarget {
    pub bucket: Option<String>,
    pub key: Option<String>,
}

/// Decodes an origin-form path into the path-style S3 bucket and key.
pub fn parse_path_style(raw_path: &str) -> Result<PathStyleTarget, HttpParseError> {
    if !raw_path.starts_with('/') || raw_path.contains('?') || raw_path.contains('#') {
        return Err(HttpParseError::InvalidRequestTarget);
    }
    if raw_path == "/" {
        return Ok(PathStyleTarget {
            bucket: None,
            key: None,
        });
    }

    let rest = &raw_path[1..];
    let (bucket_raw, key_raw) = match rest.split_once('/') {
        Some((bucket, key)) => (bucket, Some(key)),
        None => (rest, None),
    };
    let bucket_bytes = percent_decode(bucket_raw.as_bytes())?;
    if bucket_bytes.is_empty()
        || bucket_bytes.contains(&b'/')
        || bucket_bytes.iter().any(|byte| byte.is_ascii_control())
    {
        return Err(HttpParseError::InvalidBucket);
    }
    if bucket_bytes.contains(&0) {
        return Err(HttpParseError::NulInPath);
    }
    let bucket = String::from_utf8(bucket_bytes).map_err(|_| HttpParseError::InvalidUtf8Path)?;

    let key = key_raw
        .map(|raw| {
            let bytes = percent_decode(raw.as_bytes())?;
            if bytes.contains(&0) {
                return Err(HttpParseError::NulInPath);
            }
            String::from_utf8(bytes).map_err(|_| HttpParseError::InvalidUtf8Path)
        })
        .transpose()?;
    Ok(PathStyleTarget {
        bucket: Some(bucket),
        key,
    })
}

fn parse_complete_head(bytes: &[u8], limits: HeadLimits) -> Result<RequestHead, HttpParseError> {
    let raw_lines: Vec<_> = bytes.split(|byte| *byte == b'\n').collect();
    let mut lines = raw_lines.iter().enumerate().map(|(index, line)| {
        if index + 1 == raw_lines.len() {
            if line.contains(&b'\r') {
                Err(HttpParseError::InvalidHeaderValue)
            } else {
                Ok(*line)
            }
        } else {
            strip_cr(line)
        }
    });
    let request_line = lines.next().ok_or(HttpParseError::InvalidRequestLine)??;
    if request_line.len() > limits.max_request_line_bytes {
        return Err(HttpParseError::RequestLineTooLarge);
    }
    let mut words = request_line.split(|byte| *byte == b' ');
    let method = words.next().ok_or(HttpParseError::InvalidRequestLine)?;
    let target = words.next().ok_or(HttpParseError::InvalidRequestLine)?;
    let version = words.next().ok_or(HttpParseError::InvalidRequestLine)?;
    if words.next().is_some() || method.is_empty() || !method.iter().copied().all(is_tchar) {
        return Err(HttpParseError::InvalidRequestLine);
    }
    if version != b"HTTP/1.1" {
        return Err(HttpParseError::UnsupportedHttpVersion);
    }
    if !target.starts_with(b"/")
        || target.iter().any(|byte| !(0x21..=0x7e).contains(byte))
        || target.contains(&b'#')
    {
        return Err(HttpParseError::InvalidRequestTarget);
    }
    let target = std::str::from_utf8(target).map_err(|_| HttpParseError::InvalidRequestTarget)?;
    let (raw_path, raw_query) = match target.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (target, None),
    };
    // Validate all escapes before authentication; the raw spelling remains
    // available for SigV4 canonicalization.
    let _ = percent_decode(raw_path.as_bytes())?;
    let query = QueryParams::parse(raw_query.unwrap_or(""))?;

    let mut fields = Vec::new();
    for (index, raw_line) in lines.enumerate() {
        if index >= limits.max_headers {
            return Err(HttpParseError::TooManyHeaders);
        }
        let line = raw_line?;
        if line.len() > limits.max_header_line_bytes {
            return Err(HttpParseError::HeaderLineTooLarge);
        }
        if line.is_empty() || matches!(line.first(), Some(b' ' | b'\t')) {
            return Err(HttpParseError::InvalidHeaderValue);
        }
        let colon = line
            .iter()
            .position(|byte| *byte == b':')
            .ok_or(HttpParseError::InvalidHeaderName)?;
        let name = &line[..colon];
        if name.is_empty() || !name.iter().copied().all(is_tchar) {
            return Err(HttpParseError::InvalidHeaderName);
        }
        let value = trim_ows(&line[colon + 1..]);
        if !valid_field_value(value) {
            return Err(HttpParseError::InvalidHeaderValue);
        }
        fields.push(Header {
            name: String::from_utf8(name.to_ascii_lowercase()).expect("HTTP token names are ASCII"),
            value: value.to_vec(),
        });
    }
    if fields.len() > limits.max_headers {
        return Err(HttpParseError::TooManyHeaders);
    }
    let headers = HeaderMap { fields };

    let host_count = headers.get_all("host").count();
    if host_count == 0 {
        return Err(HttpParseError::MissingHost);
    }
    if host_count != 1 || headers.get("host").is_some_and(|host| host.is_empty()) {
        return Err(HttpParseError::DuplicateHost);
    }

    let (content_length, transfer_chunked) = {
        let mut content_lengths = headers.get_all("content-length");
        let content_length = content_lengths
            .next()
            .map(parse_content_length)
            .transpose()?;
        if content_lengths.next().is_some() {
            return Err(HttpParseError::InvalidContentLength);
        }
        let transfer_values: Vec<_> = headers.get_all("transfer-encoding").collect();
        if content_length.is_some() && !transfer_values.is_empty() {
            return Err(HttpParseError::AmbiguousBodyFraming);
        }
        let transfer_chunked = if transfer_values.is_empty() {
            false
        } else {
            let combined = transfer_values
                .iter()
                .flat_map(|value| value.split(|byte| *byte == b','))
                .map(trim_ows)
                .collect::<Vec<_>>();
            if combined.len() != 1 || !combined[0].eq_ignore_ascii_case(b"chunked") {
                return Err(HttpParseError::UnsupportedTransferEncoding);
            }
            true
        };
        (content_length, transfer_chunked)
    };

    Ok(RequestHead {
        method: String::from_utf8(method.to_vec()).expect("HTTP method is ASCII"),
        target: RequestTarget {
            raw_path: raw_path.to_owned(),
            raw_query: raw_query.map(str::to_owned),
            query,
        },
        headers,
        content_length,
        transfer_chunked,
    })
}

fn parse_content_length(value: &[u8]) -> Result<u64, HttpParseError> {
    if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
        return Err(HttpParseError::InvalidContentLength);
    }
    let mut result = 0_u64;
    for digit in value {
        result = result
            .checked_mul(10)
            .and_then(|value| value.checked_add(u64::from(digit - b'0')))
            .ok_or(HttpParseError::InvalidContentLength)?;
    }
    Ok(result)
}

fn strip_cr(line: &[u8]) -> Result<&[u8], HttpParseError> {
    line.strip_suffix(b"\r")
        .ok_or(HttpParseError::InvalidHeaderValue)
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

fn valid_field_value(value: &[u8]) -> bool {
    value
        .iter()
        .all(|byte| *byte == b'\t' || *byte >= 0x20 && *byte != 0x7f)
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

pub(crate) fn percent_decode(input: &[u8]) -> Result<Vec<u8>, HttpParseError> {
    let mut result = Vec::with_capacity(input.len());
    let mut index = 0;
    while index < input.len() {
        if input[index] != b'%' {
            result.push(input[index]);
            index += 1;
            continue;
        }
        if index + 2 >= input.len() {
            return Err(HttpParseError::InvalidPercentEncoding);
        }
        let high = hex_value(input[index + 1]).ok_or(HttpParseError::InvalidPercentEncoding)?;
        let low = hex_value(input[index + 2]).ok_or(HttpParseError::InvalidPercentEncoding)?;
        result.push((high << 4) | low);
        index += 3;
    }
    Ok(result)
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_incremental_head_and_preserves_body_prefix() {
        let mut parser = RequestHeadParser::new(HeadLimits::default());
        assert!(
            parser
                .push(b"PUT /bucket/a%20b?versionId=3 HTTP/1.1\r\nHo")
                .unwrap()
                .is_none()
        );
        let request = parser
            .push(b"st: localhost:9000\r\nContent-Length: 3\r\nX-Test:  a\t b  \r\n\r\nabc")
            .unwrap()
            .unwrap();
        assert_eq!(request.method, "PUT");
        assert_eq!(request.target.raw_path, "/bucket/a%20b");
        assert_eq!(request.target.query.get("versionId"), Some(b"3".as_slice()));
        assert_eq!(request.headers.get("x-test"), Some(b"a\t b".as_slice()));
        assert_eq!(request.content_length, Some(3));
        assert_eq!(parser.take_remainder(), b"abc");
    }

    #[test]
    fn rejects_request_smuggling_framing() {
        let mut parser = RequestHeadParser::new(HeadLimits::default());
        let error = parser
            .push(b"PUT /b/k HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n")
            .unwrap_err();
        assert_eq!(error, HttpParseError::AmbiguousBodyFraming);
    }

    #[test]
    fn enforces_limits_before_unbounded_buffering() {
        let mut parser = RequestHeadParser::new(HeadLimits {
            max_head_bytes: 16,
            ..HeadLimits::default()
        });
        assert_eq!(
            parser.push(b"GET / HTTP/1.1\r\nX").unwrap_err(),
            HttpParseError::HeadTooLarge
        );
    }

    #[test]
    fn path_style_preserves_key_slashes_and_decodes_utf8() {
        let parsed = parse_path_style("/my-bucket/a//snowman-%E2%98%83").unwrap();
        assert_eq!(parsed.bucket.as_deref(), Some("my-bucket"));
        assert_eq!(parsed.key.as_deref(), Some("a//snowman-☃"));
        assert_eq!(
            parse_path_style("/bucket/%00").unwrap_err(),
            HttpParseError::NulInPath
        );
    }

    #[test]
    fn query_plus_is_not_form_space_and_duplicates_survive() {
        let query = QueryParams::parse("tag=a+b&tag=a%20b&acl").unwrap();
        assert_eq!(
            query.get_all("tag").collect::<Vec<_>>(),
            vec![b"a+b", b"a b"]
        );
        assert_eq!(query.get("acl"), Some(b"".as_slice()));
    }
}
