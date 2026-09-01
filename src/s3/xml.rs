use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::protocol::xml::S3_XMLNS;

use super::db::{ListRecord, PartRecord, VersionRecord};
use super::route::{ListParams, VersionListParams};

pub(crate) fn iso8601(milliseconds: i64) -> String {
    let seconds = milliseconds.div_euclid(1000);
    let millis = milliseconds.rem_euclid(1000);
    let days = seconds.div_euclid(86_400);
    let seconds_of_day = seconds.rem_euclid(86_400);
    let (year, month, day) = civil_from_days(days);
    let hour = seconds_of_day / 3600;
    let minute = seconds_of_day % 3600 / 60;
    let second = seconds_of_day % 60;
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z")
}

pub(crate) fn system_time(milliseconds: i64) -> SystemTime {
    if milliseconds >= 0 {
        UNIX_EPOCH + Duration::from_millis(milliseconds as u64)
    } else {
        UNIX_EPOCH - Duration::from_millis(milliseconds.unsigned_abs())
    }
}

pub(crate) fn list_objects_v1(
    bucket: &str,
    params: &ListParams,
    records: &[ListRecord],
) -> Vec<u8> {
    let truncated = is_list_truncated(params.max_keys, records);
    let mut out = document("ListBucketResult");
    element(&mut out, "Name", bucket);
    element(&mut out, "Prefix", &params.prefix);
    encoded_element(
        &mut out,
        "Marker",
        params.marker.as_deref().unwrap_or(""),
        params.encoding_type_url,
    );
    if truncated {
        let next = records
            .last()
            .and_then(|record| record.key.as_deref().or(record.common_prefix.as_deref()))
            .unwrap_or("");
        encoded_element(&mut out, "NextMarker", next, params.encoding_type_url);
    }
    element(&mut out, "MaxKeys", &params.max_keys.to_string());
    if let Some(delimiter) = &params.delimiter {
        element(&mut out, "Delimiter", delimiter);
    }
    if params.encoding_type_url {
        element(&mut out, "EncodingType", "url");
    }
    element(&mut out, "IsTruncated", bool_text(truncated));
    append_list_records(&mut out, records, params.encoding_type_url);
    close(out, "ListBucketResult")
}

pub(crate) fn list_objects_v2(
    bucket: &str,
    params: &ListParams,
    records: &[ListRecord],
) -> Vec<u8> {
    let truncated = is_list_truncated(params.max_keys, records);
    let mut out = document("ListBucketResult");
    element(&mut out, "Name", bucket);
    element(&mut out, "Prefix", &params.prefix);
    element(&mut out, "MaxKeys", &params.max_keys.to_string());
    element(&mut out, "KeyCount", &records.len().to_string());
    if let Some(delimiter) = &params.delimiter {
        element(&mut out, "Delimiter", delimiter);
    }
    if let Some(token) = &params.requested_continuation_token {
        element(&mut out, "ContinuationToken", token);
    }
    if let Some(start_after) = &params.requested_start_after {
        encoded_element(
            &mut out,
            "StartAfter",
            start_after,
            params.encoding_type_url,
        );
    }
    if params.encoding_type_url {
        element(&mut out, "EncodingType", "url");
    }
    element(&mut out, "IsTruncated", bool_text(truncated));
    if truncated
        && let Some(token) = records
            .last()
            .and_then(|record| record.continuation_token.as_deref())
    {
        element(&mut out, "NextContinuationToken", token);
    }
    append_list_records(&mut out, records, params.encoding_type_url);
    close(out, "ListBucketResult")
}

pub(crate) fn list_versions(
    bucket: &str,
    params: &VersionListParams,
    records: &[VersionRecord],
) -> Vec<u8> {
    let truncated = params.max_keys > 0
        && records.len() == params.max_keys as usize
        && records
            .last()
            .and_then(|record| record.next_key_marker.as_ref())
            .is_some();
    let mut out = document("ListVersionsResult");
    element(&mut out, "Name", bucket);
    element(&mut out, "Prefix", &params.prefix);
    encoded_element(
        &mut out,
        "KeyMarker",
        params.key_marker.as_deref().unwrap_or(""),
        params.encoding_type_url,
    );
    if let Some(version) = params.version_id_marker {
        element(&mut out, "VersionIdMarker", &version.to_string());
    }
    if truncated {
        let last = records.last().expect("truncated list has a row");
        if let Some(marker) = &last.next_key_marker {
            encoded_element(&mut out, "NextKeyMarker", marker, params.encoding_type_url);
        }
        if let Some(version) = last.next_version_id_marker {
            element(&mut out, "NextVersionIdMarker", &version.to_string());
        }
    }
    element(&mut out, "MaxKeys", &params.max_keys.to_string());
    if let Some(delimiter) = &params.delimiter {
        element(&mut out, "Delimiter", delimiter);
    }
    if params.encoding_type_url {
        element(&mut out, "EncodingType", "url");
    }
    element(&mut out, "IsTruncated", bool_text(truncated));
    for record in records {
        if let Some(prefix) = &record.common_prefix {
            out.push_str("<CommonPrefixes>");
            encoded_common_prefix(&mut out, prefix, params.encoding_type_url);
            out.push_str("</CommonPrefixes>");
            continue;
        }
        let tag = if record.delete_marker == Some(true) {
            "DeleteMarker"
        } else {
            "Version"
        };
        out.push('<');
        out.push_str(tag);
        out.push('>');
        encoded_element(
            &mut out,
            "Key",
            record.key.as_deref().unwrap_or(""),
            params.encoding_type_url,
        );
        element(
            &mut out,
            "VersionId",
            &record.version_id.unwrap_or_default().to_string(),
        );
        element(
            &mut out,
            "IsLatest",
            bool_text(record.is_latest.unwrap_or(false)),
        );
        if let Some(last_modified) = record.last_modified_ms {
            element(&mut out, "LastModified", &iso8601(last_modified));
        }
        if tag == "Version" {
            element(
                &mut out,
                "ETag",
                &format!("\"{}\"", record.etag.as_deref().unwrap_or("")),
            );
            element(
                &mut out,
                "Size",
                &record.size.unwrap_or_default().to_string(),
            );
            owner(&mut out);
            element(&mut out, "StorageClass", "STANDARD");
        } else {
            owner(&mut out);
        }
        out.push_str("</");
        out.push_str(tag);
        out.push('>');
    }
    close(out, "ListVersionsResult")
}

pub(crate) fn list_parts(
    bucket: &str,
    key: &str,
    upload_id: &str,
    marker: i32,
    max_parts: i32,
    parts: &[PartRecord],
) -> Vec<u8> {
    let eligible: Vec<_> = parts
        .iter()
        .filter(|part| part.part_number > marker)
        .collect();
    let truncated = eligible.len() > max_parts as usize;
    let page = &eligible[..eligible.len().min(max_parts as usize)];
    let next_marker = page.last().map(|part| part.part_number).unwrap_or(marker);
    let mut out = document("ListPartsResult");
    element(&mut out, "Bucket", bucket);
    element(&mut out, "Key", key);
    element(&mut out, "UploadId", upload_id);
    element(&mut out, "PartNumberMarker", &marker.to_string());
    if truncated {
        element(&mut out, "NextPartNumberMarker", &next_marker.to_string());
    }
    element(&mut out, "MaxParts", &max_parts.to_string());
    element(&mut out, "IsTruncated", bool_text(truncated));
    for part in page {
        out.push_str("<Part>");
        element(&mut out, "PartNumber", &part.part_number.to_string());
        element(&mut out, "LastModified", &iso8601(part.completed_ms));
        element(&mut out, "ETag", &format!("\"{}\"", part.etag));
        element(&mut out, "Size", &part.size.to_string());
        out.push_str("</Part>");
    }
    close(out, "ListPartsResult")
}

fn append_list_records(out: &mut String, records: &[ListRecord], encode: bool) {
    for record in records {
        if let Some(prefix) = &record.common_prefix {
            out.push_str("<CommonPrefixes>");
            encoded_common_prefix(out, prefix, encode);
            out.push_str("</CommonPrefixes>");
            continue;
        }
        out.push_str("<Contents>");
        encoded_element(out, "Key", record.key.as_deref().unwrap_or(""), encode);
        if let Some(last_modified) = record.last_modified_ms {
            element(out, "LastModified", &iso8601(last_modified));
        }
        element(
            out,
            "ETag",
            &format!("\"{}\"", record.etag.as_deref().unwrap_or("")),
        );
        element(out, "Size", &record.size.unwrap_or_default().to_string());
        element(out, "StorageClass", "STANDARD");
        out.push_str("</Contents>");
    }
}

fn is_list_truncated(max_keys: i32, records: &[ListRecord]) -> bool {
    max_keys > 0
        && records.len() == max_keys as usize
        && records
            .last()
            .and_then(|record| record.continuation_token.as_ref())
            .is_some()
}

fn owner(out: &mut String) {
    out.push_str("<Owner>");
    element(out, "ID", "pgs3");
    element(out, "DisplayName", "pgs3");
    out.push_str("</Owner>");
}

fn document(root: &str) -> String {
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?><{root} xmlns=\"{S3_XMLNS}\">")
}

fn close(mut out: String, root: &str) -> Vec<u8> {
    out.push_str("</");
    out.push_str(root);
    out.push('>');
    out.into_bytes()
}

fn encoded_element(out: &mut String, name: &str, value: &str, encode: bool) {
    if encode {
        element(out, name, &url_encode(value));
    } else {
        element(out, name, value);
    }
}

fn encoded_common_prefix(out: &mut String, value: &str, encode: bool) {
    if encode {
        element(out, "Prefix", &url_encode_preserving_slashes(value));
    } else {
        element(out, "Prefix", value);
    }
}

fn element(out: &mut String, name: &str, value: &str) {
    out.push('<');
    out.push_str(name);
    out.push('>');
    escape(out, value);
    out.push_str("</");
    out.push_str(name);
    out.push('>');
}

fn escape(out: &mut String, value: &str) {
    for character in value.chars() {
        match character {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            character => out.push(character),
        }
    }
}

fn url_encode(value: &str) -> String {
    url_encode_bytes(value, false)
}

fn url_encode_preserving_slashes(value: &str) -> String {
    url_encode_bytes(value, true)
}

fn url_encode_bytes(value: &str, preserve_slashes: bool) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        if byte.is_ascii_alphanumeric()
            || matches!(*byte, b'-' | b'_' | b'.' | b'~')
            || (preserve_slashes && *byte == b'/')
        {
            out.push(char::from(*byte));
        } else {
            out.push('%');
            out.push(hex(byte >> 4));
            out.push(hex(byte & 0x0f));
        }
    }
    out
}

fn hex(nibble: u8) -> char {
    char::from(if nibble < 10 {
        b'0' + nibble
    } else {
        b'A' + nibble - 10
    })
}

fn bool_text(value: bool) -> &'static str {
    if value { "true" } else { "false" }
}

// Howard Hinnant's civil calendar conversion, with Unix day zero offset.
fn civil_from_days(days_since_epoch: i64) -> (i64, i64, i64) {
    let z = days_since_epoch + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month, day)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats_epoch_and_leap_day() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(iso8601(1_709_164_800_123), "2024-02-29T00:00:00.123Z");
    }

    #[test]
    fn list_xml_escapes_and_url_encodes_keys() {
        let params = ListParams {
            prefix: "a/".into(),
            max_keys: 1000,
            encoding_type_url: true,
            ..ListParams::default()
        };
        let xml = String::from_utf8(list_objects_v2(
            "bucket",
            &params,
            &[ListRecord {
                key: Some("a/<x>".into()),
                common_prefix: None,
                version_id: Some(1),
                size: Some(3),
                etag: Some("abcd".into()),
                last_modified_ms: Some(0),
                continuation_token: Some("token".into()),
            }],
        ))
        .unwrap();
        assert!(xml.contains("<Key>a%2F%3Cx%3E</Key>"));
        assert!(xml.contains("<Prefix>a/</Prefix>"));
    }

    #[test]
    fn list_url_encoding_preserves_common_prefix_slashes() {
        let params = ListParams {
            delimiter: Some("/".into()),
            max_keys: 1000,
            encoding_type_url: true,
            ..ListParams::default()
        };
        let records = [
            ListRecord {
                key: None,
                common_prefix: Some("foo+1/nested/".into()),
                version_id: None,
                size: None,
                etag: None,
                last_modified_ms: None,
                continuation_token: None,
            },
            ListRecord {
                key: None,
                common_prefix: Some("quux ab/".into()),
                version_id: None,
                size: None,
                etag: None,
                last_modified_ms: None,
                continuation_token: None,
            },
        ];
        for bytes in [
            list_objects_v1("bucket", &params, &records),
            list_objects_v2("bucket", &params, &records),
        ] {
            let xml = String::from_utf8(bytes).unwrap();
            assert!(xml.contains("<Prefix>foo%2B1/nested/</Prefix>"));
            assert!(xml.contains("<Prefix>quux%20ab/</Prefix>"));
            assert!(!xml.contains("%2F"));
        }
    }

    #[test]
    fn list_v2_echoes_empty_token_and_start_after_even_when_token_wins() {
        let empty = ListParams {
            continuation_token: None,
            requested_continuation_token: Some(String::new()),
            max_keys: 1000,
            ..ListParams::default()
        };
        let xml = String::from_utf8(list_objects_v2("bucket", &empty, &[])).unwrap();
        assert!(xml.contains("<ContinuationToken></ContinuationToken>"));

        let resumed = ListParams {
            start_after: None,
            continuation_token: Some("opaque".into()),
            requested_start_after: Some("bar".into()),
            requested_continuation_token: Some("opaque".into()),
            max_keys: 1000,
            ..ListParams::default()
        };
        let xml = String::from_utf8(list_objects_v2("bucket", &resumed, &[])).unwrap();
        assert!(xml.contains("<ContinuationToken>opaque</ContinuationToken>"));
        assert!(xml.contains("<StartAfter>bar</StartAfter>"));
    }

    #[test]
    fn url_encoding_leaves_request_echo_fields_readable() {
        let params = ListParams {
            prefix: "a/".into(),
            delimiter: Some("/".into()),
            max_keys: 1000,
            encoding_type_url: true,
            ..ListParams::default()
        };
        for bytes in [
            list_objects_v1("bucket", &params, &[]),
            list_objects_v2("bucket", &params, &[]),
        ] {
            let xml = String::from_utf8(bytes).unwrap();
            assert!(xml.contains("<Prefix>a/</Prefix>"));
            assert!(xml.contains("<Delimiter>/</Delimiter>"));
            assert!(xml.contains("<EncodingType>url</EncodingType>"));
        }
    }

    #[test]
    fn zero_max_keys_is_empty_and_never_truncated() {
        let list_params = ListParams {
            max_keys: 0,
            ..ListParams::default()
        };
        for bytes in [
            list_objects_v1("bucket", &list_params, &[]),
            list_objects_v2("bucket", &list_params, &[]),
        ] {
            let xml = String::from_utf8(bytes).unwrap();
            assert!(xml.contains("<MaxKeys>0</MaxKeys>"));
            assert!(xml.contains("<IsTruncated>false</IsTruncated>"));
            assert!(!xml.contains("<NextMarker>"));
            assert!(!xml.contains("<NextContinuationToken>"));
        }

        let version_params = VersionListParams {
            max_keys: 0,
            ..VersionListParams::default()
        };
        let xml = String::from_utf8(list_versions("bucket", &version_params, &[])).unwrap();
        assert!(xml.contains("<MaxKeys>0</MaxKeys>"));
        assert!(xml.contains("<IsTruncated>false</IsTruncated>"));
        assert!(!xml.contains("<NextKeyMarker>"));
        assert!(!xml.contains("<NextVersionIdMarker>"));
    }
}
