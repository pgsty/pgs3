use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::protocol::xml::{S3ErrorResponse, serialize_error};

static REQUEST_SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ServiceResponse {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl ServiceResponse {
    pub(crate) fn empty(status: u16) -> Self {
        Self {
            status,
            headers: Vec::new(),
            body: Vec::new(),
        }
    }

    pub(crate) fn xml(status: u16, body: Vec<u8>) -> Self {
        Self {
            status,
            headers: vec![("content-type".into(), "application/xml".into())],
            body,
        }
    }

    pub(crate) fn header(mut self, name: &str, value: impl Into<String>) -> Self {
        self.headers.push((name.to_owned(), value.into()));
        self
    }

    pub(crate) fn finalize(mut self, request_id: &str, head_only: bool) -> Self {
        self.headers
            .push(("x-amz-request-id".to_owned(), request_id.to_owned()));
        self.headers
            .push(("x-amz-id-2".to_owned(), request_id.to_owned()));
        self.headers
            .push(("connection".to_owned(), "keep-alive".to_owned()));
        let body_len = self.body.len();
        if !self
            .headers
            .iter()
            .any(|(name, _)| name.eq_ignore_ascii_case("content-length"))
        {
            self.headers
                .push(("content-length".to_owned(), body_len.to_string()));
        }
        if head_only {
            self.body.clear();
        }
        self
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct S3Error {
    pub status: u16,
    pub code: &'static str,
    pub message: String,
}

impl S3Error {
    pub(crate) fn new(status: u16, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
        }
    }

    pub(crate) fn invalid_request(message: impl Into<String>) -> Self {
        Self::new(400, "InvalidRequest", message)
    }

    pub(crate) fn access_denied() -> Self {
        Self::new(403, "AccessDenied", "Access Denied")
    }

    pub(crate) fn internal() -> Self {
        Self::new(500, "InternalError", "We encountered an internal error")
    }

    pub(crate) fn response(&self, resource: &str, request_id: &str) -> ServiceResponse {
        ServiceResponse::xml(
            self.status,
            serialize_error(&S3ErrorResponse {
                code: self.code,
                message: &self.message,
                resource: Some(resource),
                request_id,
                host_id: Some(request_id),
            }),
        )
    }
}

pub(crate) fn request_id() -> String {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos() as u64;
    let sequence = REQUEST_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    format!("{timestamp:016X}{sequence:08X}")
}

#[cfg(test)]
mod tests {
    use super::ServiceResponse;

    #[test]
    fn head_finalize_preserves_exactly_one_semantic_content_length() {
        let response = ServiceResponse::empty(200)
            .header("Content-Length", "123")
            .finalize("request", true);
        let lengths: Vec<_> = response
            .headers
            .iter()
            .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
            .map(|(_, value)| value.as_str())
            .collect();
        assert_eq!(lengths, ["123"]);
        assert!(response.body.is_empty());

        let response = ServiceResponse::xml(404, b"error".to_vec()).finalize("request", true);
        let lengths: Vec<_> = response
            .headers
            .iter()
            .filter(|(name, _)| name.eq_ignore_ascii_case("content-length"))
            .map(|(_, value)| value.as_str())
            .collect();
        assert_eq!(lengths, ["5"]);
        assert!(response.body.is_empty());
    }
}
