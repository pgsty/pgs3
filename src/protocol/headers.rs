//! Parsing and evaluation for S3 Range and conditional request headers.

use std::fmt;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::http::HeaderMap;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ByteRangeSpec {
    Inclusive { first: u64, last: u64 },
    From { first: u64 },
    Suffix { length: u64 },
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ResolvedRange {
    pub start: u64,
    /// Inclusive end offset.
    pub end: u64,
}

impl ResolvedRange {
    #[must_use]
    pub fn len(self) -> u64 {
        self.end - self.start + 1
    }

    #[must_use]
    #[allow(dead_code)]
    pub fn is_empty(self) -> bool {
        false
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RangeError {
    UnsupportedUnit,
    MultipleRangesUnsupported,
    InvalidSyntax,
    InvalidNumber,
    Unsatisfiable,
}

impl fmt::Display for RangeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}",
            match self {
                Self::UnsupportedUnit => "only byte ranges are supported",
                Self::MultipleRangesUnsupported =>
                    "S3 does not support multiple ranges in one request",
                Self::InvalidSyntax => "invalid Range header syntax",
                Self::InvalidNumber => "Range header offset is not a valid u64",
                Self::Unsatisfiable => "requested range is not satisfiable",
            }
        )
    }
}

impl std::error::Error for RangeError {}

impl ByteRangeSpec {
    pub fn parse(value: &[u8]) -> Result<Self, RangeError> {
        let value = trim_ascii(value);
        let (unit, range) = split_once(value, b'=').ok_or(RangeError::InvalidSyntax)?;
        if !unit.eq_ignore_ascii_case(b"bytes") {
            return Err(RangeError::UnsupportedUnit);
        }
        if range.contains(&b',') {
            return Err(RangeError::MultipleRangesUnsupported);
        }
        let (first, last) = split_once(range, b'-').ok_or(RangeError::InvalidSyntax)?;
        if first.is_empty() {
            let length = parse_u64(last)?;
            if length == 0 {
                return Err(RangeError::Unsatisfiable);
            }
            return Ok(Self::Suffix { length });
        }
        let first = parse_u64(first)?;
        if last.is_empty() {
            return Ok(Self::From { first });
        }
        let last = parse_u64(last)?;
        if first > last {
            return Err(RangeError::Unsatisfiable);
        }
        Ok(Self::Inclusive { first, last })
    }

    pub fn resolve(self, object_size: u64) -> Result<ResolvedRange, RangeError> {
        if object_size == 0 {
            return Err(RangeError::Unsatisfiable);
        }
        let final_byte = object_size - 1;
        match self {
            Self::Inclusive { first, last } => {
                if first >= object_size {
                    return Err(RangeError::Unsatisfiable);
                }
                Ok(ResolvedRange {
                    start: first,
                    end: last.min(final_byte),
                })
            }
            Self::From { first } => {
                if first >= object_size {
                    return Err(RangeError::Unsatisfiable);
                }
                Ok(ResolvedRange {
                    start: first,
                    end: final_byte,
                })
            }
            Self::Suffix { length } => Ok(ResolvedRange {
                start: object_size.saturating_sub(length),
                end: final_byte,
            }),
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EntityTag {
    pub weak: bool,
    pub opaque: Vec<u8>,
}

impl EntityTag {
    pub fn parse(value: &[u8]) -> Result<Self, ConditionalError> {
        let value = trim_ascii(value);
        let (weak, quoted) = if value.starts_with(b"W/") {
            (true, &value[2..])
        } else {
            (false, value)
        };
        if quoted.len() < 2 || quoted[0] != b'"' || quoted[quoted.len() - 1] != b'"' {
            return Err(ConditionalError::InvalidEntityTag);
        }
        let opaque = &quoted[1..quoted.len() - 1];
        if !opaque
            .iter()
            .all(|byte| *byte == 0x21 || *byte >= 0x23 && *byte != 0x7f)
        {
            return Err(ConditionalError::InvalidEntityTag);
        }
        Ok(Self {
            weak,
            opaque: opaque.to_vec(),
        })
    }

    #[must_use]
    pub fn strong_eq(&self, other: &Self) -> bool {
        !self.weak && !other.weak && self.opaque == other.opaque
    }

    #[must_use]
    pub fn weak_eq(&self, other: &Self) -> bool {
        self.opaque == other.opaque
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum TagCondition {
    Any,
    Tags(Vec<EntityTag>),
}

impl TagCondition {
    pub fn parse(value: &[u8]) -> Result<Self, ConditionalError> {
        let value = trim_ascii(value);
        if value == b"*" {
            return Ok(Self::Any);
        }
        // S3 accepts the common SDK/API spelling where a single opaque ETag
        // is supplied without HTTP quotes. Keep comma-separated HTTP lists
        // strict so ambiguous values are still rejected.
        if !value.starts_with(b"\"") && !value.starts_with(b"W/\"") {
            if !value.is_empty()
                && !value.contains(&b',')
                && value
                    .iter()
                    .all(|byte| *byte >= 0x21 && *byte != b'"' && *byte != 0x7f)
            {
                return Ok(Self::Tags(vec![EntityTag {
                    weak: false,
                    opaque: value.to_vec(),
                }]));
            }
            return Err(ConditionalError::InvalidEntityTag);
        }
        let mut tags = Vec::new();
        let mut remainder = value;
        while !remainder.is_empty() {
            remainder = trim_ascii_start(remainder);
            let quote = if remainder.starts_with(b"W/\"") {
                2
            } else if remainder.starts_with(b"\"") {
                0
            } else {
                return Err(ConditionalError::InvalidEntityTag);
            };
            let close = remainder[quote + 1..]
                .iter()
                .position(|byte| *byte == b'"')
                .map(|position| quote + 1 + position)
                .ok_or(ConditionalError::InvalidEntityTag)?;
            tags.push(EntityTag::parse(&remainder[..=close])?);
            remainder = trim_ascii_start(&remainder[close + 1..]);
            if remainder.is_empty() {
                break;
            }
            if remainder[0] != b',' {
                return Err(ConditionalError::InvalidEntityTag);
            }
            remainder = &remainder[1..];
            if trim_ascii_start(remainder).is_empty() {
                return Err(ConditionalError::InvalidEntityTag);
            }
        }
        if tags.is_empty() {
            return Err(ConditionalError::InvalidEntityTag);
        }
        Ok(Self::Tags(tags))
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ConditionalHeaders {
    pub if_match: Option<TagCondition>,
    pub if_none_match: Option<TagCondition>,
    pub if_modified_since: Option<SystemTime>,
    pub if_unmodified_since: Option<SystemTime>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PreconditionResult {
    Proceed,
    NotModified,
    PreconditionFailed,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ConditionalError {
    DuplicateHeader(&'static str),
    InvalidEntityTag,
    InvalidHttpDate,
}

impl fmt::Display for ConditionalError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DuplicateHeader(name) => write!(f, "duplicate conditional header: {name}"),
            Self::InvalidEntityTag => f.write_str("invalid HTTP entity-tag"),
            Self::InvalidHttpDate => f.write_str("invalid HTTP date in conditional header"),
        }
    }
}

impl std::error::Error for ConditionalError {}

impl ConditionalHeaders {
    pub fn parse(headers: &HeaderMap) -> Result<Self, ConditionalError> {
        Ok(Self {
            if_match: one(headers, "if-match")?
                .map(TagCondition::parse)
                .transpose()?,
            if_none_match: one(headers, "if-none-match")?
                .map(TagCondition::parse)
                .transpose()?,
            if_modified_since: one(headers, "if-modified-since")?
                .map(parse_http_date)
                .transpose()?,
            if_unmodified_since: one(headers, "if-unmodified-since")?
                .map(parse_http_date)
                .transpose()?,
        })
    }

    /// Evaluates RFC 9110 ordering. `is_get_or_head` selects 304 rather than
    /// 412 for a matching `If-None-Match` on safe retrieval methods.
    #[must_use]
    pub fn evaluate(
        &self,
        current_etag: Option<&EntityTag>,
        last_modified: Option<SystemTime>,
        is_get_or_head: bool,
    ) -> PreconditionResult {
        if let Some(condition) = &self.if_match {
            let matched = match condition {
                TagCondition::Any => current_etag.is_some(),
                TagCondition::Tags(tags) => current_etag.is_some_and(|current| {
                    tags.iter().any(|candidate| candidate.strong_eq(current))
                }),
            };
            if !matched {
                return PreconditionResult::PreconditionFailed;
            }
        } else if let (Some(since), Some(modified)) = (self.if_unmodified_since, last_modified)
            && second_precision(modified) > second_precision(since)
        {
            return PreconditionResult::PreconditionFailed;
        }

        if let Some(condition) = &self.if_none_match {
            let matched = match condition {
                TagCondition::Any => current_etag.is_some(),
                TagCondition::Tags(tags) => current_etag
                    .is_some_and(|current| tags.iter().any(|candidate| candidate.weak_eq(current))),
            };
            if matched {
                return if is_get_or_head {
                    PreconditionResult::NotModified
                } else {
                    PreconditionResult::PreconditionFailed
                };
            }
        } else if is_get_or_head
            && let (Some(since), Some(modified)) = (self.if_modified_since, last_modified)
            && second_precision(modified) <= second_precision(since)
        {
            return PreconditionResult::NotModified;
        }
        PreconditionResult::Proceed
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum IfRange {
    EntityTag(EntityTag),
    Date(SystemTime),
}

impl IfRange {
    pub fn parse(value: &[u8]) -> Result<Self, ConditionalError> {
        let value = trim_ascii(value);
        if value.starts_with(b"\"") || value.starts_with(b"W/\"") {
            return EntityTag::parse(value).map(Self::EntityTag);
        }
        parse_http_date(value).map(Self::Date)
    }

    #[must_use]
    pub fn permits_range(&self, current_etag: &EntityTag, last_modified: SystemTime) -> bool {
        match self {
            // If-Range entity-tag comparison is strong; a weak tag never matches.
            Self::EntityTag(expected) => expected.strong_eq(current_etag),
            Self::Date(date) => second_precision(last_modified) <= second_precision(*date),
        }
    }
}

fn one<'a>(
    headers: &'a HeaderMap,
    name: &'static str,
) -> Result<Option<&'a [u8]>, ConditionalError> {
    let mut values = headers.get_all(name);
    let value = values.next();
    if values.next().is_some() {
        return Err(ConditionalError::DuplicateHeader(name));
    }
    Ok(value)
}

fn parse_http_date(value: &[u8]) -> Result<SystemTime, ConditionalError> {
    let value =
        std::str::from_utf8(trim_ascii(value)).map_err(|_| ConditionalError::InvalidHttpDate)?;
    httpdate::parse_http_date(value).map_err(|_| ConditionalError::InvalidHttpDate)
}

fn second_precision(time: SystemTime) -> Duration {
    Duration::from_secs(
        time.duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs(),
    )
}

fn parse_u64(value: &[u8]) -> Result<u64, RangeError> {
    if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
        return Err(RangeError::InvalidNumber);
    }
    let mut number = 0_u64;
    for byte in value {
        number = number
            .checked_mul(10)
            .and_then(|number| number.checked_add(u64::from(byte - b'0')))
            .ok_or(RangeError::InvalidNumber)?;
    }
    Ok(number)
}

fn trim_ascii(mut value: &[u8]) -> &[u8] {
    while value.first().is_some_and(u8::is_ascii_whitespace) {
        value = &value[1..];
    }
    while value.last().is_some_and(u8::is_ascii_whitespace) {
        value = &value[..value.len() - 1];
    }
    value
}

fn trim_ascii_start(mut value: &[u8]) -> &[u8] {
    while value.first().is_some_and(u8::is_ascii_whitespace) {
        value = &value[1..];
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

    #[test]
    fn resolves_all_single_range_forms() {
        assert_eq!(
            ByteRangeSpec::parse(b"bytes=10-19")
                .unwrap()
                .resolve(15)
                .unwrap(),
            ResolvedRange { start: 10, end: 14 }
        );
        assert_eq!(
            ByteRangeSpec::parse(b"bytes=10-")
                .unwrap()
                .resolve(20)
                .unwrap(),
            ResolvedRange { start: 10, end: 19 }
        );
        assert_eq!(
            ByteRangeSpec::parse(b"bytes=-5")
                .unwrap()
                .resolve(20)
                .unwrap(),
            ResolvedRange { start: 15, end: 19 }
        );
        assert_eq!(
            ByteRangeSpec::parse(b"bytes=-50")
                .unwrap()
                .resolve(20)
                .unwrap(),
            ResolvedRange { start: 0, end: 19 }
        );
        assert_eq!(
            ByteRangeSpec::parse(b"bytes=20-").unwrap().resolve(20),
            Err(RangeError::Unsatisfiable)
        );
    }

    #[test]
    fn s3_rejects_multi_range() {
        assert_eq!(
            ByteRangeSpec::parse(b"bytes=0-1,4-5"),
            Err(RangeError::MultipleRangesUnsupported)
        );
    }

    #[test]
    fn evaluates_safe_and_mutating_if_none_match_differently() {
        let current = EntityTag::parse(b"\"abc\"").unwrap();
        let conditions = ConditionalHeaders {
            if_none_match: Some(TagCondition::Any),
            ..ConditionalHeaders::default()
        };
        assert_eq!(
            conditions.evaluate(Some(&current), None, true),
            PreconditionResult::NotModified
        );
        assert_eq!(
            conditions.evaluate(Some(&current), None, false),
            PreconditionResult::PreconditionFailed
        );
        assert_eq!(
            conditions.evaluate(None, None, false),
            PreconditionResult::Proceed
        );
    }

    #[test]
    fn entity_tag_lists_allow_commas_inside_opaque_tags() {
        assert_eq!(
            TagCondition::parse(b"W/\"a,b\", \"c\"").unwrap(),
            TagCondition::Tags(vec![
                EntityTag {
                    weak: true,
                    opaque: b"a,b".to_vec(),
                },
                EntityTag {
                    weak: false,
                    opaque: b"c".to_vec(),
                },
            ])
        );
    }

    #[test]
    fn s3_accepts_one_legacy_unquoted_entity_tag() {
        assert_eq!(
            TagCondition::parse(b"ABCORZ").unwrap(),
            TagCondition::Tags(vec![EntityTag {
                weak: false,
                opaque: b"ABCORZ".to_vec(),
            }])
        );
        assert_eq!(
            TagCondition::parse(b"abc,def"),
            Err(ConditionalError::InvalidEntityTag)
        );
    }

    #[test]
    fn if_match_takes_precedence_over_unmodified_since() {
        let current = EntityTag::parse(b"\"abc\"").unwrap();
        let conditions = ConditionalHeaders {
            if_match: Some(TagCondition::Tags(vec![current.clone()])),
            if_unmodified_since: Some(UNIX_EPOCH),
            ..ConditionalHeaders::default()
        };
        assert_eq!(
            conditions.evaluate(Some(&current), Some(SystemTime::now()), false),
            PreconditionResult::Proceed
        );
    }

    #[test]
    fn parses_all_standard_http_date_forms() {
        for date in [
            b"Sun, 06 Nov 1994 08:49:37 GMT".as_slice(),
            b"Sunday, 06-Nov-94 08:49:37 GMT".as_slice(),
            b"Sun Nov  6 08:49:37 1994".as_slice(),
        ] {
            assert!(parse_http_date(date).is_ok());
        }
    }
}
