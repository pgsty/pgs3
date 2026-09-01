use crate::protocol::http::{HeaderMap, QueryParams, RequestHead, parse_path_style};

use super::types::S3Error;

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) enum Operation {
    ListBuckets,
    CreateBucket {
        bucket: String,
    },
    DeleteBucket {
        bucket: String,
    },
    HeadBucket {
        bucket: String,
    },
    GetBucketLocation {
        bucket: String,
    },
    GetBucketVersioning {
        bucket: String,
    },
    ListObjectsV1 {
        bucket: String,
        params: ListParams,
    },
    ListObjectsV2 {
        bucket: String,
        params: ListParams,
    },
    ListObjectVersions {
        bucket: String,
        params: VersionListParams,
    },
    PutObject {
        bucket: String,
        key: String,
    },
    CopyObject {
        bucket: String,
        key: String,
        source: CopySource,
    },
    RestoreObject {
        bucket: String,
        key: String,
        version_id: i64,
    },
    GetObject {
        bucket: String,
        key: String,
        version_id: Option<i64>,
    },
    HeadObject {
        bucket: String,
        key: String,
        version_id: Option<i64>,
    },
    DeleteObject {
        bucket: String,
        key: String,
        version_id: Option<i64>,
    },
    DeleteObjects {
        bucket: String,
    },
    CreateMultipartUpload {
        bucket: String,
        key: String,
    },
    UploadPart {
        bucket: String,
        key: String,
        upload_id: String,
        part_number: i32,
    },
    CompleteMultipartUpload {
        bucket: String,
        key: String,
        upload_id: String,
    },
    AbortMultipartUpload {
        bucket: String,
        key: String,
        upload_id: String,
    },
    ListParts {
        bucket: String,
        key: String,
        upload_id: String,
        params: ListPartsParams,
    },
}

impl Operation {
    pub(crate) fn name(&self) -> &'static str {
        match self {
            Self::ListBuckets => "ListBuckets",
            Self::CreateBucket { .. } => "CreateBucket",
            Self::DeleteBucket { .. } => "DeleteBucket",
            Self::HeadBucket { .. } => "HeadBucket",
            Self::GetBucketLocation { .. } => "GetBucketLocation",
            Self::GetBucketVersioning { .. } => "GetBucketVersioning",
            Self::ListObjectsV1 { .. } => "ListObjects",
            Self::ListObjectsV2 { .. } => "ListObjectsV2",
            Self::ListObjectVersions { .. } => "ListObjectVersions",
            Self::PutObject { .. } => "PutObject",
            Self::CopyObject { .. } => "CopyObject",
            Self::RestoreObject { .. } => "RestoreObject",
            Self::GetObject { .. } => "GetObject",
            Self::HeadObject { .. } => "HeadObject",
            Self::DeleteObject { .. } => "DeleteObject",
            Self::DeleteObjects { .. } => "DeleteObjects",
            Self::CreateMultipartUpload { .. } => "CreateMultipartUpload",
            Self::UploadPart { .. } => "UploadPart",
            Self::CompleteMultipartUpload { .. } => "CompleteMultipartUpload",
            Self::AbortMultipartUpload { .. } => "AbortMultipartUpload",
            Self::ListParts { .. } => "ListParts",
        }
    }

    pub(crate) fn is_head(&self) -> bool {
        matches!(self, Self::HeadBucket { .. } | Self::HeadObject { .. })
    }

    pub(crate) fn streams_object_body(&self) -> bool {
        matches!(self, Self::PutObject { .. } | Self::UploadPart { .. })
    }

    pub(crate) fn requires_xml_body(&self) -> bool {
        matches!(
            self,
            Self::DeleteObjects { .. } | Self::CompleteMultipartUpload { .. }
        )
    }
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct ListParams {
    pub prefix: String,
    pub delimiter: Option<String>,
    pub marker: Option<String>,
    /// Effective initial cursor passed to the database.  A non-empty
    /// continuation token supersedes this value.
    pub start_after: Option<String>,
    /// Effective opaque cursor passed to the database.  Empty request values
    /// are treated as absent here, but retained in `requested_continuation_token`
    /// for the response echo required by S3.
    pub continuation_token: Option<String>,
    pub requested_start_after: Option<String>,
    pub requested_continuation_token: Option<String>,
    pub max_keys: i32,
    pub encoding_type_url: bool,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub(crate) struct VersionListParams {
    pub prefix: String,
    pub delimiter: Option<String>,
    pub key_marker: Option<String>,
    pub version_id_marker: Option<i64>,
    pub max_keys: i32,
    pub encoding_type_url: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CopySource {
    pub bucket: String,
    pub key: String,
    pub version_id: Option<i64>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct ListPartsParams {
    pub part_number_marker: i32,
    pub max_parts: i32,
}

pub(crate) fn classify(request: &RequestHead) -> Result<Operation, S3Error> {
    let path = parse_path_style(&request.target.raw_path)
        .map_err(|error| S3Error::invalid_request(error.to_string()))?;
    let key = path.key.filter(|key| !key.is_empty());
    let query = &request.target.query;
    let method = request.method.as_str();

    let Some(bucket) = path.bucket else {
        return if method == "GET" && query.pairs().is_empty() {
            Ok(Operation::ListBuckets)
        } else {
            Err(unsupported())
        };
    };

    if let Some(key) = key {
        classify_object(method, bucket, key, query, &request.headers)
    } else {
        classify_bucket(method, bucket, query)
    }
}

fn classify_bucket(
    method: &str,
    bucket: String,
    query: &QueryParams,
) -> Result<Operation, S3Error> {
    match method {
        "PUT" if query.pairs().is_empty() => Ok(Operation::CreateBucket { bucket }),
        "DELETE" if query.pairs().is_empty() => Ok(Operation::DeleteBucket { bucket }),
        "HEAD" if query.pairs().is_empty() => Ok(Operation::HeadBucket { bucket }),
        "GET" if has_flag(query, "location")? => Ok(Operation::GetBucketLocation { bucket }),
        "GET" if has_flag(query, "versioning")? => Ok(Operation::GetBucketVersioning { bucket }),
        "GET" if has_flag(query, "versions")? => Ok(Operation::ListObjectVersions {
            bucket,
            params: parse_version_list(query)?,
        }),
        "GET" => {
            let list_type = optional_one(query, "list-type")?;
            let params = parse_list(query)?;
            match list_type.as_deref() {
                None | Some("1") => Ok(Operation::ListObjectsV1 { bucket, params }),
                Some("2") => Ok(Operation::ListObjectsV2 { bucket, params }),
                Some(_) => Err(S3Error::invalid_request("list-type must be 1 or 2")),
            }
        }
        "POST" if has_flag(query, "delete")? => Ok(Operation::DeleteObjects { bucket }),
        _ => Err(unsupported()),
    }
}

fn classify_object(
    method: &str,
    bucket: String,
    key: String,
    query: &QueryParams,
    headers: &HeaderMap,
) -> Result<Operation, S3Error> {
    let upload_id = optional_one(query, "uploadId")?;
    let version_id = optional_i64(query, "versionId")?;
    let part_number = optional_i32(query, "partNumber")?;
    match method {
        "POST" if has_flag(query, "uploads")? => {
            Ok(Operation::CreateMultipartUpload { bucket, key })
        }
        "POST" if let Some(upload_id) = upload_id.as_ref() => {
            validate_multipart_upload_id(upload_id)?;
            Ok(Operation::CompleteMultipartUpload {
                bucket,
                key,
                upload_id: upload_id.clone(),
            })
        }
        "PUT" if let (Some(upload_id), Some(part_number)) = (upload_id.as_ref(), part_number) => {
            if !(1..=10_000).contains(&part_number) {
                return Err(S3Error::new(
                    400,
                    "InvalidArgument",
                    "partNumber must be 1..10000",
                ));
            }
            Ok(Operation::UploadPart {
                bucket,
                key,
                upload_id: upload_id.clone(),
                part_number,
            })
        }
        "DELETE" if let Some(upload_id) = upload_id.as_ref() => {
            validate_multipart_upload_id(upload_id)?;
            Ok(Operation::AbortMultipartUpload {
                bucket,
                key,
                upload_id: upload_id.clone(),
            })
        }
        "GET" if let Some(upload_id) = upload_id.as_ref() => {
            validate_query_names(
                query,
                &[
                    "uploadId",
                    "part-number-marker",
                    "max-parts",
                    "encoding-type",
                    "X-Amz-Algorithm",
                    "X-Amz-Credential",
                    "X-Amz-Date",
                    "X-Amz-Expires",
                    "X-Amz-SignedHeaders",
                    "X-Amz-Signature",
                    "X-Amz-Security-Token",
                ],
            )?;
            if optional_one(query, "encoding-type")?
                .as_deref()
                .is_some_and(|v| v != "url")
            {
                return Err(S3Error::new(
                    400,
                    "InvalidArgument",
                    "encoding-type must be url",
                ));
            }
            let part_number_marker = optional_i32(query, "part-number-marker")?.unwrap_or(0);
            let max_parts = optional_i32(query, "max-parts")?.unwrap_or(1000);
            if !(0..=10_000).contains(&part_number_marker) || !(0..=1000).contains(&max_parts) {
                return Err(S3Error::new(
                    400,
                    "InvalidArgument",
                    "part-number-marker must be 0..10000 and max-parts must be 0..1000",
                ));
            }
            Ok(Operation::ListParts {
                bucket,
                key,
                upload_id: upload_id.clone(),
                params: ListPartsParams {
                    part_number_marker,
                    max_parts,
                },
            })
        }
        "PUT" if headers.get("x-amz-copy-source").is_some() => Ok(Operation::CopyObject {
            bucket,
            key,
            source: parse_copy_source(headers)?,
        }),
        "POST" if has_flag(query, "restore")? => Ok(Operation::RestoreObject {
            bucket,
            key,
            version_id: version_id.ok_or_else(|| {
                S3Error::new(400, "InvalidArgument", "restore requires versionId")
            })?,
        }),
        "PUT" if valid_put_query(query)? => Ok(Operation::PutObject { bucket, key }),
        "GET" if only_version_query(query, "GetObject")? => Ok(Operation::GetObject {
            bucket,
            key,
            version_id,
        }),
        "HEAD" if only_version_query(query, "HeadObject")? => Ok(Operation::HeadObject {
            bucket,
            key,
            version_id,
        }),
        "DELETE" if only_version_query(query, "DeleteObject")? => Ok(Operation::DeleteObject {
            bucket,
            key,
            version_id,
        }),
        _ => Err(unsupported()),
    }
}

fn parse_list(query: &QueryParams) -> Result<ListParams, S3Error> {
    validate_query_names(
        query,
        &[
            "list-type",
            "prefix",
            "delimiter",
            "marker",
            "start-after",
            "continuation-token",
            "max-keys",
            "encoding-type",
            "fetch-owner",
            "X-Amz-Algorithm",
            "X-Amz-Credential",
            "X-Amz-Date",
            "X-Amz-Expires",
            "X-Amz-SignedHeaders",
            "X-Amz-Signature",
            "X-Amz-Security-Token",
        ],
    )?;
    let requested_start_after = optional_one(query, "start-after")?;
    let requested_continuation_token = optional_one(query, "continuation-token")?;
    let continuation_token = requested_continuation_token
        .clone()
        .filter(|value| !value.is_empty());
    // AWS treats an empty continuation token as absent. A real token resumes
    // an opaque server cursor and therefore supersedes StartAfter.
    let start_after = if continuation_token.is_none() {
        requested_start_after.clone()
    } else {
        None
    };
    Ok(ListParams {
        prefix: optional_one(query, "prefix")?.unwrap_or_default(),
        delimiter: optional_one(query, "delimiter")?.filter(|value| !value.is_empty()),
        marker: optional_one(query, "marker")?,
        start_after,
        continuation_token,
        requested_start_after,
        requested_continuation_token,
        max_keys: max_keys(query)?,
        encoding_type_url: encoding_type(query)?,
    })
}

fn validate_multipart_upload_id(upload_id: &str) -> Result<(), S3Error> {
    let bytes = upload_id.as_bytes();
    let valid = bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                byte.is_ascii_hexdigit()
            }
        });
    if valid {
        Ok(())
    } else {
        Err(S3Error::new(
            404,
            "NoSuchUpload",
            "The specified upload does not exist",
        ))
    }
}

fn parse_version_list(query: &QueryParams) -> Result<VersionListParams, S3Error> {
    validate_query_names(
        query,
        &[
            "versions",
            "prefix",
            "delimiter",
            "key-marker",
            "version-id-marker",
            "max-keys",
            "encoding-type",
            "X-Amz-Algorithm",
            "X-Amz-Credential",
            "X-Amz-Date",
            "X-Amz-Expires",
            "X-Amz-SignedHeaders",
            "X-Amz-Signature",
            "X-Amz-Security-Token",
        ],
    )?;
    let key_marker = optional_one(query, "key-marker")?;
    let version_id_marker = optional_i64(query, "version-id-marker")?;
    if version_id_marker.is_some() && key_marker.is_none() {
        return Err(S3Error::new(
            400,
            "InvalidArgument",
            "version-id-marker requires key-marker",
        ));
    }
    Ok(VersionListParams {
        prefix: optional_one(query, "prefix")?.unwrap_or_default(),
        delimiter: optional_one(query, "delimiter")?.filter(|value| !value.is_empty()),
        key_marker,
        version_id_marker,
        max_keys: max_keys(query)?,
        encoding_type_url: encoding_type(query)?,
    })
}

fn parse_copy_source(headers: &HeaderMap) -> Result<CopySource, S3Error> {
    let values: Vec<_> = headers.get_all("x-amz-copy-source").collect();
    if values.len() != 1 {
        return Err(S3Error::invalid_request(
            "x-amz-copy-source must appear once",
        ));
    }
    let raw = std::str::from_utf8(values[0])
        .map_err(|_| S3Error::invalid_request("x-amz-copy-source is not UTF-8"))?;
    let (raw_path, raw_query) = raw.split_once('?').unwrap_or((raw, ""));
    let path = if raw_path.starts_with('/') {
        raw_path.to_owned()
    } else {
        format!("/{raw_path}")
    };
    let parsed =
        parse_path_style(&path).map_err(|error| S3Error::invalid_request(error.to_string()))?;
    let source_query = QueryParams::parse(raw_query)
        .map_err(|error| S3Error::invalid_request(error.to_string()))?;
    if source_query
        .pairs()
        .iter()
        .any(|pair| pair.name != b"versionId")
    {
        return Err(S3Error::invalid_request("invalid copy source query"));
    }
    Ok(CopySource {
        bucket: parsed
            .bucket
            .ok_or_else(|| S3Error::invalid_request("copy source has no bucket"))?,
        key: parsed
            .key
            .filter(|key| !key.is_empty())
            .ok_or_else(|| S3Error::invalid_request("copy source has no object key"))?,
        version_id: optional_i64(&source_query, "versionId")?,
    })
}

fn max_keys(query: &QueryParams) -> Result<i32, S3Error> {
    let value = optional_i32(query, "max-keys")?.unwrap_or(1000);
    if !(0..=1000).contains(&value) {
        return Err(S3Error::new(
            400,
            "InvalidArgument",
            "max-keys must be 0..1000",
        ));
    }
    Ok(value)
}

fn encoding_type(query: &QueryParams) -> Result<bool, S3Error> {
    match optional_one(query, "encoding-type")?.as_deref() {
        None => Ok(false),
        Some("url") => Ok(true),
        Some(_) => Err(S3Error::new(
            400,
            "InvalidArgument",
            "encoding-type must be url",
        )),
    }
}

fn only_version_query(query: &QueryParams, operation_id: &str) -> Result<bool, S3Error> {
    validate_query_names(
        query,
        &[
            "versionId",
            "X-Amz-Algorithm",
            "X-Amz-Credential",
            "X-Amz-Date",
            "X-Amz-Expires",
            "X-Amz-SignedHeaders",
            "X-Amz-Signature",
            "X-Amz-Security-Token",
            "x-id",
        ],
    )?;
    if let Some(value) = optional_one(query, "x-id")?
        && value != operation_id
    {
        return Err(unsupported());
    }
    Ok(true)
}

fn valid_put_query(query: &QueryParams) -> Result<bool, S3Error> {
    validate_query_names(
        query,
        &[
            "X-Amz-Algorithm",
            "X-Amz-Credential",
            "X-Amz-Date",
            "X-Amz-Expires",
            "X-Amz-SignedHeaders",
            "X-Amz-Signature",
            "X-Amz-Security-Token",
            "x-id",
        ],
    )?;
    if let Some(value) = optional_one(query, "x-id")?
        && value != "PutObject"
    {
        return Err(unsupported());
    }
    Ok(true)
}

fn validate_query_names(query: &QueryParams, allowed: &[&str]) -> Result<(), S3Error> {
    for pair in query.pairs() {
        let name = std::str::from_utf8(&pair.name)
            .map_err(|_| S3Error::invalid_request("query name is not UTF-8"))?;
        if !allowed.contains(&name) {
            return Err(unsupported());
        }
    }
    Ok(())
}

fn has_flag(query: &QueryParams, name: &str) -> Result<bool, S3Error> {
    let values: Vec<_> = query.get_all(name).collect();
    if values.len() > 1 {
        return Err(S3Error::invalid_request(format!(
            "duplicate query parameter {name}"
        )));
    }
    Ok(values.len() == 1)
}

fn optional_one(query: &QueryParams, name: &str) -> Result<Option<String>, S3Error> {
    let values: Vec<_> = query.get_all(name).collect();
    if values.len() > 1 {
        return Err(S3Error::invalid_request(format!(
            "duplicate query parameter {name}"
        )));
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

fn optional_i64(query: &QueryParams, name: &str) -> Result<Option<i64>, S3Error> {
    optional_one(query, name)?
        .map(|value| {
            value
                .parse::<i64>()
                .ok()
                .filter(|value| *value > 0)
                .ok_or_else(|| S3Error::new(400, "InvalidArgument", format!("{name} is invalid")))
        })
        .transpose()
}

fn optional_i32(query: &QueryParams, name: &str) -> Result<Option<i32>, S3Error> {
    optional_one(query, name)?
        .map(|value| {
            value
                .parse::<i32>()
                .map_err(|_| S3Error::new(400, "InvalidArgument", format!("{name} is invalid")))
        })
        .transpose()
}

fn unsupported() -> S3Error {
    S3Error::new(
        501,
        "NotImplemented",
        "The requested S3 operation is not implemented",
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::http::{HeadLimits, RequestHeadParser};

    fn request(raw: &str) -> RequestHead {
        let mut parser = RequestHeadParser::new(HeadLimits::default());
        parser.push(raw.as_bytes()).unwrap().unwrap()
    }

    #[test]
    fn classifies_required_bucket_and_listing_routes() {
        assert_eq!(
            classify(&request("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")).unwrap(),
            Operation::ListBuckets
        );
        let route = classify(&request(
            "GET /bucket?list-type=2&prefix=a%2F&delimiter=%2F&max-keys=37 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ))
        .unwrap();
        match route {
            Operation::ListObjectsV2 { bucket, params } => {
                assert_eq!(bucket, "bucket");
                assert_eq!(params.prefix, "a/");
                assert_eq!(params.delimiter.as_deref(), Some("/"));
                assert_eq!(params.max_keys, 37);
            }
            other => panic!("wrong route: {other:?}"),
        }
    }

    #[test]
    fn list_v2_separates_request_echoes_from_effective_cursors() {
        let empty = classify(&request(
            "GET /bucket?list-type=2&continuation-token=&start-after=bar HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ))
        .unwrap();
        match empty {
            Operation::ListObjectsV2 { params, .. } => {
                assert_eq!(params.continuation_token, None);
                assert_eq!(params.start_after.as_deref(), Some("bar"));
                assert_eq!(params.requested_continuation_token.as_deref(), Some(""));
                assert_eq!(params.requested_start_after.as_deref(), Some("bar"));
            }
            other => panic!("wrong route: {other:?}"),
        }

        let resumed = classify(&request(
            "GET /bucket?list-type=2&continuation-token=opaque&start-after=ignored HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ))
        .unwrap();
        match resumed {
            Operation::ListObjectsV2 { params, .. } => {
                assert_eq!(params.continuation_token.as_deref(), Some("opaque"));
                assert_eq!(params.start_after, None);
                assert_eq!(
                    params.requested_continuation_token.as_deref(),
                    Some("opaque")
                );
                assert_eq!(params.requested_start_after.as_deref(), Some("ignored"));
            }
            other => panic!("wrong route: {other:?}"),
        }
    }

    #[test]
    fn classifies_multipart_and_version_routes() {
        assert!(matches!(
            classify(&request(
                "POST /b/k?uploads HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
            ))
            .unwrap(),
            Operation::CreateMultipartUpload { .. }
        ));
        assert!(matches!(
            classify(&request(
                "PUT /b/k?partNumber=7&uploadId=abc HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"
            ))
            .unwrap(),
            Operation::UploadPart { part_number: 7, .. }
        ));
        assert!(matches!(
            classify(&request(
                "GET /b?versions&key-marker=k&version-id-marker=8 HTTP/1.1\r\nHost: localhost\r\n\r\n"
            ))
            .unwrap(),
            Operation::ListObjectVersions { .. }
        ));
        let list_parts = classify(&request(
            "GET /b/k?uploadId=abc&part-number-marker=7&max-parts=23 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ))
        .unwrap();
        assert!(matches!(
            list_parts,
            Operation::ListParts {
                params: ListPartsParams {
                    part_number_marker: 7,
                    max_parts: 23
                },
                ..
            }
        ));

        for raw in [
            "POST /b/k?uploadId=01234567-89ab-cdef-0123-456789abcdef HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
            "DELETE /b/k?uploadId=01234567-89AB-CDEF-0123-456789ABCDEF HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ] {
            assert!(matches!(
                classify(&request(raw)).unwrap(),
                Operation::CompleteMultipartUpload { .. } | Operation::AbortMultipartUpload { .. }
            ));
        }
    }

    #[test]
    fn complete_and_abort_invalid_upload_ids_are_not_found() {
        for raw in [
            "POST /b/k?uploadId=abc1234def HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
            "DELETE /b/k?uploadId=56788 HTTP/1.1\r\nHost: localhost\r\n\r\n",
            "POST /b/k?uploadId= HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
            "DELETE /b/k?uploadId HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ] {
            let error = classify(&request(raw)).unwrap_err();
            assert_eq!((error.status, error.code), (404, "NoSuchUpload"));
        }
    }

    #[test]
    fn presigned_put_auth_query_still_routes_to_put_object() {
        let route = classify(&request(
            "PUT /b/k?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKID%2F20260831%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20260831T000000Z&X-Amz-Expires=60&X-Amz-SignedHeaders=host&X-Amz-Signature=0000000000000000000000000000000000000000000000000000000000000000&x-id=PutObject HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n",
        ))
        .unwrap();
        assert!(matches!(route, Operation::PutObject { .. }));
    }

    #[test]
    fn get_object_accepts_matching_sdk_operation_id_query() {
        let route = classify(&request(
            "GET /b/k?x-id=GetObject HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ))
        .unwrap();
        assert!(matches!(route, Operation::GetObject { .. }));

        let error = classify(&request(
            "GET /b/k?x-id=PutObject HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ))
        .unwrap_err();
        assert_eq!(error.code, "NotImplemented");
    }

    #[test]
    fn copy_source_is_percent_decoded_and_versioned() {
        let route = classify(&request(
            "PUT /dst/to HTTP/1.1\r\nHost: localhost\r\nx-amz-copy-source: /src/a%2Fb?versionId=9\r\nContent-Length: 0\r\n\r\n",
        ))
        .unwrap();
        match route {
            Operation::CopyObject { source, .. } => {
                assert_eq!(source.bucket, "src");
                assert_eq!(source.key, "a/b");
                assert_eq!(source.version_id, Some(9));
            }
            other => panic!("wrong route: {other:?}"),
        }
    }

    #[test]
    fn rejects_ambiguous_and_unknown_query_parameters() {
        let error = classify(&request(
            "GET /b?list-type=2&max-keys=1&max-keys=2 HTTP/1.1\r\nHost: localhost\r\n\r\n",
        ))
        .unwrap_err();
        assert_eq!(error.code, "InvalidRequest");
        let error =
            classify(&request("GET /b/k?acl HTTP/1.1\r\nHost: localhost\r\n\r\n")).unwrap_err();
        assert_eq!(error.code, "NotImplemented");
    }
}
