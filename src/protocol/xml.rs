//! Bounded XML parsing and deterministic S3 XML response serialization.

use std::fmt;

use quick_xml::Reader;
use quick_xml::events::Event;

pub const S3_XMLNS: &str = "http://s3.amazonaws.com/doc/2006-03-01/";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct XmlLimits {
    pub max_document_bytes: usize,
    pub max_depth: usize,
    pub max_nodes: usize,
    pub max_text_bytes: usize,
    pub max_complete_parts: usize,
    pub max_delete_objects: usize,
}

impl Default for XmlLimits {
    fn default() -> Self {
        Self {
            max_document_bytes: 1024 * 1024,
            max_depth: 16,
            max_nodes: 32_000,
            max_text_bytes: 1024 * 1024,
            max_complete_parts: 10_000,
            max_delete_objects: 1_000,
        }
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum XmlError {
    DocumentTooLarge,
    TooDeep,
    TooManyNodes,
    TextTooLarge,
    Malformed(String),
    ForbiddenConstruct,
    MissingRoot,
    MultipleRoots,
    UnexpectedRoot {
        expected: &'static str,
        actual: String,
    },
    UnexpectedElement(String),
    MissingField(&'static str),
    DuplicateField(&'static str),
    InvalidField(&'static str),
    TooManyItems,
    PartNumbersNotIncreasing,
}

impl fmt::Display for XmlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::DocumentTooLarge => f.write_str("XML document exceeds its size limit"),
            Self::TooDeep => f.write_str("XML nesting exceeds its depth limit"),
            Self::TooManyNodes => f.write_str("XML document has too many elements"),
            Self::TextTooLarge => f.write_str("XML text exceeds its size limit"),
            Self::Malformed(error) => write!(f, "malformed XML: {error}"),
            Self::ForbiddenConstruct => {
                f.write_str("DTD and processing instructions are forbidden")
            }
            Self::MissingRoot => f.write_str("XML document has no root element"),
            Self::MultipleRoots => f.write_str("XML document has multiple root elements"),
            Self::UnexpectedRoot { expected, actual } => {
                write!(f, "expected XML root {expected}, got {actual}")
            }
            Self::UnexpectedElement(element) => write!(f, "unexpected XML element {element}"),
            Self::MissingField(field) => write!(f, "missing XML field {field}"),
            Self::DuplicateField(field) => write!(f, "duplicate XML field {field}"),
            Self::InvalidField(field) => write!(f, "invalid XML field {field}"),
            Self::TooManyItems => f.write_str("XML request contains too many items"),
            Self::PartNumbersNotIncreasing => {
                f.write_str("multipart part numbers must be strictly increasing")
            }
        }
    }
}

impl std::error::Error for XmlError {}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct PartChecksums {
    pub crc32: Option<String>,
    pub crc32c: Option<String>,
    pub sha1: Option<String>,
    pub sha256: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompletedPart {
    pub part_number: u16,
    pub etag: String,
    pub checksums: PartChecksums,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompleteMultipartUpload {
    pub parts: Vec<CompletedPart>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeleteObjectIdentifier {
    pub key: String,
    pub version_id: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DeleteObjectsRequest {
    pub objects: Vec<DeleteObjectIdentifier>,
    pub quiet: bool,
}

/// Parses the request body for CompleteMultipartUpload. Part numbers are
/// range-checked and required to be strictly increasing, matching S3's
/// `InvalidPartOrder` rule.
pub fn parse_complete_multipart(
    input: &[u8],
    limits: XmlLimits,
) -> Result<CompleteMultipartUpload, XmlError> {
    let root = parse_tree(input, limits)?;
    expect_root(&root, "CompleteMultipartUpload")?;
    let mut parts = Vec::new();
    let mut previous = 0_u16;
    for child in &root.children {
        if child.name != "Part" {
            if child.text.trim().is_empty() && child.children.is_empty() {
                return Err(XmlError::UnexpectedElement(child.name.clone()));
            }
            return Err(XmlError::UnexpectedElement(child.name.clone()));
        }
        if parts.len() >= limits.max_complete_parts {
            return Err(XmlError::TooManyItems);
        }
        let number = required_once(child, "PartNumber")?;
        let part_number = number
            .text
            .trim()
            .parse::<u16>()
            .ok()
            .filter(|number| (1..=10_000).contains(number))
            .ok_or(XmlError::InvalidField("PartNumber"))?;
        if part_number <= previous {
            return Err(XmlError::PartNumbersNotIncreasing);
        }
        previous = part_number;

        let etag = required_once(child, "ETag")?.text.trim().to_owned();
        if etag.is_empty() {
            return Err(XmlError::InvalidField("ETag"));
        }
        let checksums = PartChecksums {
            crc32: optional_text(child, "ChecksumCRC32")?,
            crc32c: optional_text(child, "ChecksumCRC32C")?,
            sha1: optional_text(child, "ChecksumSHA1")?,
            sha256: optional_text(child, "ChecksumSHA256")?,
        };
        reject_unknown_children(
            child,
            &[
                "PartNumber",
                "ETag",
                "ChecksumCRC32",
                "ChecksumCRC32C",
                "ChecksumSHA1",
                "ChecksumSHA256",
            ],
        )?;
        parts.push(CompletedPart {
            part_number,
            etag,
            checksums,
        });
    }
    if parts.is_empty() {
        return Err(XmlError::MissingField("Part"));
    }
    Ok(CompleteMultipartUpload { parts })
}

/// Parses the body of DeleteObjects (multi-object delete).
pub fn parse_delete_objects(
    input: &[u8],
    limits: XmlLimits,
) -> Result<DeleteObjectsRequest, XmlError> {
    let root = parse_tree(input, limits)?;
    expect_root(&root, "Delete")?;
    let mut objects = Vec::new();
    let mut quiet = false;
    let mut saw_quiet = false;
    for child in &root.children {
        match child.name.as_str() {
            "Object" => {
                if objects.len() >= limits.max_delete_objects {
                    return Err(XmlError::TooManyItems);
                }
                reject_unknown_children(child, &["Key", "VersionId"])?;
                let key_node = required_once(child, "Key")?;
                if key_node.text.is_empty() {
                    return Err(XmlError::InvalidField("Key"));
                }
                objects.push(DeleteObjectIdentifier {
                    // Spaces are legal object-key bytes and must not be trimmed.
                    key: key_node.text.clone(),
                    version_id: optional_text_untrimmed(child, "VersionId")?,
                });
            }
            "Quiet" => {
                if saw_quiet {
                    return Err(XmlError::DuplicateField("Quiet"));
                }
                saw_quiet = true;
                quiet = match child.text.trim() {
                    value if value.eq_ignore_ascii_case("true") => true,
                    value if value.eq_ignore_ascii_case("false") => false,
                    _ => return Err(XmlError::InvalidField("Quiet")),
                };
            }
            _ => return Err(XmlError::UnexpectedElement(child.name.clone())),
        }
    }
    if objects.is_empty() {
        return Err(XmlError::MissingField("Object"));
    }
    Ok(DeleteObjectsRequest { objects, quiet })
}

#[derive(Clone, Debug)]
pub struct S3ErrorResponse<'a> {
    pub code: &'a str,
    pub message: &'a str,
    pub resource: Option<&'a str>,
    pub request_id: &'a str,
    pub host_id: Option<&'a str>,
}

#[must_use]
pub fn serialize_error(error: &S3ErrorResponse<'_>) -> Vec<u8> {
    let mut xml = XmlWriter::document("Error");
    xml.element("Code", error.code);
    xml.element("Message", error.message);
    if let Some(resource) = error.resource {
        xml.element("Resource", resource);
    }
    xml.element("RequestId", error.request_id);
    if let Some(host_id) = error.host_id {
        xml.element("HostId", host_id);
    }
    xml.finish("Error")
}

#[derive(Clone, Debug)]
pub struct BucketDescription<'a> {
    pub name: &'a str,
    /// ISO-8601 timestamp, already formatted by the semantic boundary.
    pub creation_date: &'a str,
}

#[must_use]
pub fn serialize_list_buckets(
    owner_id: &str,
    owner_display_name: &str,
    buckets: &[BucketDescription<'_>],
) -> Vec<u8> {
    let mut xml = XmlWriter::document_ns("ListAllMyBucketsResult");
    xml.start("Owner");
    xml.element("ID", owner_id);
    xml.element("DisplayName", owner_display_name);
    xml.end("Owner");
    xml.start("Buckets");
    for bucket in buckets {
        xml.start("Bucket");
        xml.element("Name", bucket.name);
        xml.element("CreationDate", bucket.creation_date);
        xml.end("Bucket");
    }
    xml.end("Buckets");
    xml.finish("ListAllMyBucketsResult")
}

#[must_use]
pub fn serialize_bucket_location(region: Option<&str>) -> Vec<u8> {
    let mut xml = XmlWriter::document_ns("LocationConstraint");
    if let Some(region) = region {
        xml.text(region);
    }
    xml.finish("LocationConstraint")
}

#[must_use]
pub fn serialize_versioning_enabled() -> Vec<u8> {
    let mut xml = XmlWriter::document_ns("VersioningConfiguration");
    xml.element("Status", "Enabled");
    xml.finish("VersioningConfiguration")
}

#[must_use]
pub fn serialize_initiate_multipart(
    bucket: &str,
    key: &str,
    upload_id: &str,
    checksum_algorithm: Option<&str>,
    checksum_type: Option<&str>,
) -> Vec<u8> {
    let mut xml = XmlWriter::document_ns("InitiateMultipartUploadResult");
    xml.element("Bucket", bucket);
    xml.element("Key", key);
    xml.element("UploadId", upload_id);
    if let Some(algorithm) = checksum_algorithm {
        xml.element("ChecksumAlgorithm", algorithm);
    }
    if let Some(checksum_type) = checksum_type {
        xml.element("ChecksumType", checksum_type);
    }
    xml.finish("InitiateMultipartUploadResult")
}

#[must_use]
pub fn serialize_complete_multipart(
    location: &str,
    bucket: &str,
    key: &str,
    etag: &str,
    checksum_sha256: Option<&str>,
    checksum_type: Option<&str>,
) -> Vec<u8> {
    let mut xml = XmlWriter::document_ns("CompleteMultipartUploadResult");
    xml.element("Location", location);
    xml.element("Bucket", bucket);
    xml.element("Key", key);
    xml.element("ETag", etag);
    if let Some(checksum) = checksum_sha256 {
        xml.element("ChecksumSHA256", checksum);
    }
    if let Some(checksum_type) = checksum_type {
        xml.element("ChecksumType", checksum_type);
    }
    xml.finish("CompleteMultipartUploadResult")
}

#[must_use]
pub fn serialize_copy_result(
    last_modified: &str,
    etag: &str,
    checksum_sha256: Option<&str>,
) -> Vec<u8> {
    let mut xml = XmlWriter::document("CopyObjectResult");
    xml.element("LastModified", last_modified);
    xml.element("ETag", etag);
    if let Some(checksum) = checksum_sha256 {
        xml.element("ChecksumSHA256", checksum);
    }
    xml.finish("CopyObjectResult")
}

#[derive(Clone, Debug)]
pub struct DeletedObject<'a> {
    pub key: &'a str,
    pub version_id: Option<&'a str>,
    pub delete_marker: bool,
    pub delete_marker_version_id: Option<&'a str>,
}

#[derive(Clone, Debug)]
pub struct DeleteObjectError<'a> {
    pub key: &'a str,
    pub version_id: Option<&'a str>,
    pub code: &'a str,
    pub message: &'a str,
}

#[must_use]
pub fn serialize_delete_result(
    deleted: &[DeletedObject<'_>],
    errors: &[DeleteObjectError<'_>],
) -> Vec<u8> {
    let mut xml = XmlWriter::document_ns("DeleteResult");
    for item in deleted {
        xml.start("Deleted");
        xml.element("Key", item.key);
        if let Some(version_id) = item.version_id {
            xml.element("VersionId", version_id);
        }
        if item.delete_marker {
            xml.element("DeleteMarker", "true");
        }
        if let Some(version_id) = item.delete_marker_version_id {
            xml.element("DeleteMarkerVersionId", version_id);
        }
        xml.end("Deleted");
    }
    for item in errors {
        xml.start("Error");
        xml.element("Key", item.key);
        if let Some(version_id) = item.version_id {
            xml.element("VersionId", version_id);
        }
        xml.element("Code", item.code);
        xml.element("Message", item.message);
        xml.end("Error");
    }
    xml.finish("DeleteResult")
}

#[derive(Debug)]
struct Node {
    name: String,
    text: String,
    children: Vec<Node>,
}

fn parse_tree(input: &[u8], limits: XmlLimits) -> Result<Node, XmlError> {
    if input.len() > limits.max_document_bytes {
        return Err(XmlError::DocumentTooLarge);
    }
    let mut reader = Reader::from_reader(input);
    reader.config_mut().check_end_names = true;
    reader.config_mut().expand_empty_elements = true;
    let mut stack: Vec<Node> = Vec::new();
    let mut root = None;
    let mut nodes = 0_usize;
    let mut text_bytes = 0_usize;
    let mut saw_declaration = false;

    loop {
        let event = reader
            .read_event()
            .map_err(|error| XmlError::Malformed(error.to_string()))?;
        match event {
            Event::Start(start) => {
                if stack.len() >= limits.max_depth {
                    return Err(XmlError::TooDeep);
                }
                nodes = nodes.checked_add(1).ok_or(XmlError::TooManyNodes)?;
                if nodes > limits.max_nodes {
                    return Err(XmlError::TooManyNodes);
                }
                // Force attribute parsing so duplicate/malformed attributes are
                // rejected even though request schemas do not consume them.
                for attribute in start.attributes() {
                    attribute.map_err(|error| XmlError::Malformed(error.to_string()))?;
                }
                let name = std::str::from_utf8(start.local_name().as_ref())
                    .map_err(|error| XmlError::Malformed(error.to_string()))?
                    .to_owned();
                stack.push(Node {
                    name,
                    text: String::new(),
                    children: Vec::new(),
                });
            }
            Event::End(_) => {
                let node = stack
                    .pop()
                    .ok_or_else(|| XmlError::Malformed("unmatched end tag".to_owned()))?;
                if let Some(parent) = stack.last_mut() {
                    parent.children.push(node);
                } else if root.replace(node).is_some() {
                    return Err(XmlError::MultipleRoots);
                }
            }
            Event::Text(text) => {
                let decoded = text
                    .xml10_content()
                    .map_err(|error| XmlError::Malformed(error.to_string()))?;
                let decoded = quick_xml::escape::unescape(&decoded)
                    .map_err(|error| XmlError::Malformed(error.to_string()))?;
                append_text(
                    &mut stack,
                    &mut text_bytes,
                    limits,
                    &decoded,
                    root.is_some(),
                )?;
            }
            Event::CData(text) => {
                let decoded = text
                    .xml10_content()
                    .map_err(|error| XmlError::Malformed(error.to_string()))?;
                append_text(
                    &mut stack,
                    &mut text_bytes,
                    limits,
                    &decoded,
                    root.is_some(),
                )?;
            }
            Event::Comment(_) => {}
            Event::Decl(_) if !saw_declaration && root.is_none() && stack.is_empty() => {
                saw_declaration = true;
            }
            Event::GeneralRef(reference) => {
                let decoded = reference
                    .xml10_content()
                    .map_err(|error| XmlError::Malformed(error.to_string()))?;
                let resolved = if let Some(character) = reference
                    .resolve_char_ref()
                    .map_err(|error| XmlError::Malformed(error.to_string()))?
                {
                    character.to_string()
                } else {
                    quick_xml::escape::resolve_xml_entity(&decoded)
                        .ok_or(XmlError::ForbiddenConstruct)?
                        .to_owned()
                };
                append_text(
                    &mut stack,
                    &mut text_bytes,
                    limits,
                    &resolved,
                    root.is_some(),
                )?;
            }
            Event::Decl(_) | Event::PI(_) | Event::DocType(_) => {
                return Err(XmlError::ForbiddenConstruct);
            }
            Event::Empty(_) => unreachable!("expand_empty_elements turns Empty into Start + End"),
            Event::Eof => break,
        }
    }
    if !stack.is_empty() {
        return Err(XmlError::Malformed("unclosed element".to_owned()));
    }
    root.ok_or(XmlError::MissingRoot)
}

fn append_text(
    stack: &mut [Node],
    text_bytes: &mut usize,
    limits: XmlLimits,
    text: &str,
    after_root: bool,
) -> Result<(), XmlError> {
    *text_bytes = text_bytes
        .checked_add(text.len())
        .ok_or(XmlError::TextTooLarge)?;
    if *text_bytes > limits.max_text_bytes {
        return Err(XmlError::TextTooLarge);
    }
    if let Some(node) = stack.last_mut() {
        node.text.push_str(text);
    } else if !text.trim().is_empty() {
        return Err(if after_root {
            XmlError::MultipleRoots
        } else {
            XmlError::Malformed("text outside root element".to_owned())
        });
    }
    Ok(())
}

fn expect_root(root: &Node, expected: &'static str) -> Result<(), XmlError> {
    if root.name == expected {
        Ok(())
    } else {
        Err(XmlError::UnexpectedRoot {
            expected,
            actual: root.name.clone(),
        })
    }
}

fn required_once<'a>(node: &'a Node, name: &'static str) -> Result<&'a Node, XmlError> {
    let mut matches = node.children.iter().filter(|child| child.name == name);
    let value = matches.next().ok_or(XmlError::MissingField(name))?;
    if matches.next().is_some() {
        return Err(XmlError::DuplicateField(name));
    }
    if !value.children.is_empty() {
        return Err(XmlError::InvalidField(name));
    }
    Ok(value)
}

fn optional_text(node: &Node, name: &'static str) -> Result<Option<String>, XmlError> {
    optional_text_untrimmed(node, name).map(|value| value.map(|value| value.trim().to_owned()))
}

fn optional_text_untrimmed(node: &Node, name: &'static str) -> Result<Option<String>, XmlError> {
    let mut matches = node.children.iter().filter(|child| child.name == name);
    let Some(value) = matches.next() else {
        return Ok(None);
    };
    if matches.next().is_some() {
        return Err(XmlError::DuplicateField(name));
    }
    if !value.children.is_empty() {
        return Err(XmlError::InvalidField(name));
    }
    Ok(Some(value.text.clone()))
}

fn reject_unknown_children(node: &Node, allowed: &[&str]) -> Result<(), XmlError> {
    if let Some(child) = node
        .children
        .iter()
        .find(|child| !allowed.contains(&child.name.as_str()))
    {
        return Err(XmlError::UnexpectedElement(child.name.clone()));
    }
    Ok(())
}

struct XmlWriter {
    bytes: Vec<u8>,
}

impl XmlWriter {
    fn document(root: &str) -> Self {
        let mut writer = Self {
            bytes: b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>".to_vec(),
        };
        writer.start(root);
        writer
    }

    fn document_ns(root: &str) -> Self {
        let mut writer = Self {
            bytes: b"<?xml version=\"1.0\" encoding=\"UTF-8\"?>".to_vec(),
        };
        writer.bytes.extend_from_slice(b"<");
        writer.bytes.extend_from_slice(root.as_bytes());
        writer.bytes.extend_from_slice(b" xmlns=\"");
        writer.escaped(S3_XMLNS);
        writer.bytes.extend_from_slice(b"\">");
        writer
    }

    fn start(&mut self, name: &str) {
        self.bytes.push(b'<');
        self.bytes.extend_from_slice(name.as_bytes());
        self.bytes.push(b'>');
    }

    fn end(&mut self, name: &str) {
        self.bytes.extend_from_slice(b"</");
        self.bytes.extend_from_slice(name.as_bytes());
        self.bytes.push(b'>');
    }

    fn text(&mut self, value: &str) {
        self.escaped(value);
    }

    fn element(&mut self, name: &str, value: &str) {
        self.start(name);
        self.escaped(value);
        self.end(name);
    }

    fn escaped(&mut self, value: &str) {
        for character in value.chars() {
            match character {
                '&' => self.bytes.extend_from_slice(b"&amp;"),
                '<' => self.bytes.extend_from_slice(b"&lt;"),
                '>' => self.bytes.extend_from_slice(b"&gt;"),
                '"' => self.bytes.extend_from_slice(b"&quot;"),
                '\'' => self.bytes.extend_from_slice(b"&apos;"),
                character => {
                    let mut encoded = [0_u8; 4];
                    self.bytes
                        .extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
                }
            }
        }
    }

    fn finish(mut self, root: &str) -> Vec<u8> {
        self.end(root);
        self.bytes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_aws_complete_multipart_shape_and_entities() {
        let request = parse_complete_multipart(
            br#"<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                 <Part><ETag>&quot;a&amp;b&quot;</ETag><PartNumber>1</PartNumber></Part>
                 <Part><PartNumber>2</PartNumber><ETag>"def"</ETag><ChecksumSHA256>YWJj</ChecksumSHA256></Part>
               </CompleteMultipartUpload>"#,
            XmlLimits::default(),
        )
        .unwrap();
        assert_eq!(request.parts[0].etag, "\"a&b\"");
        assert_eq!(request.parts[1].checksums.sha256.as_deref(), Some("YWJj"));
    }

    #[test]
    fn rejects_out_of_order_parts() {
        let error = parse_complete_multipart(
            b"<CompleteMultipartUpload><Part><PartNumber>2</PartNumber><ETag>x</ETag></Part><Part><PartNumber>1</PartNumber><ETag>y</ETag></Part></CompleteMultipartUpload>",
            XmlLimits::default(),
        )
        .unwrap_err();
        assert_eq!(error, XmlError::PartNumbersNotIncreasing);
    }

    #[test]
    fn delete_parser_preserves_key_whitespace_and_honors_quiet() {
        let request = parse_delete_objects(
            b"<Delete><Object><Key> a&amp;b </Key><VersionId>7</VersionId></Object><Quiet>true</Quiet></Delete>",
            XmlLimits::default(),
        )
        .unwrap();
        assert_eq!(request.objects[0].key, " a&b ");
        assert_eq!(request.objects[0].version_id.as_deref(), Some("7"));
        assert!(request.quiet);
    }

    #[test]
    fn rejects_dtd_and_oversized_requests() {
        assert_eq!(
            parse_delete_objects(
                b"<!DOCTYPE x><Delete><Object><Key>x</Key></Object></Delete>",
                XmlLimits::default(),
            )
            .unwrap_err(),
            XmlError::ForbiddenConstruct
        );
        assert_eq!(
            parse_delete_objects(
                b"<Delete><Object><Key>x</Key></Object></Delete>",
                XmlLimits {
                    max_document_bytes: 4,
                    ..XmlLimits::default()
                },
            )
            .unwrap_err(),
            XmlError::DocumentTooLarge
        );
    }

    #[test]
    fn serializers_escape_untrusted_values() {
        let bytes = serialize_error(&S3ErrorResponse {
            code: "NoSuchKey",
            message: "missing <x> & friends",
            resource: Some("/b/a\"b"),
            request_id: "req",
            host_id: None,
        });
        let xml = std::str::from_utf8(&bytes).unwrap();
        assert!(xml.contains("missing &lt;x&gt; &amp; friends"));
        assert!(xml.contains("/b/a&quot;b"));
        assert!(xml.ends_with("</Error>"));
    }

    #[test]
    fn multipart_serializers_emit_selected_composite_sha256() {
        let initiated = serialize_initiate_multipart(
            "bucket",
            "key",
            "upload",
            Some("SHA256"),
            Some("COMPOSITE"),
        );
        let initiated = std::str::from_utf8(&initiated).unwrap();
        assert!(initiated.contains("<ChecksumAlgorithm>SHA256</ChecksumAlgorithm>"));
        assert!(initiated.contains("<ChecksumType>COMPOSITE</ChecksumType>"));

        let completed = serialize_complete_multipart(
            "/bucket/key",
            "bucket",
            "key",
            "\"etag\"",
            Some("digest=-2"),
            Some("COMPOSITE"),
        );
        let completed = std::str::from_utf8(&completed).unwrap();
        assert!(completed.contains("<ChecksumSHA256>digest=-2</ChecksumSHA256>"));
        assert!(completed.contains("<ChecksumType>COMPOSITE</ChecksumType>"));
    }
}
