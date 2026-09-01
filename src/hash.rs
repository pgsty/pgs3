//! Incremental, server-trusted hashing over the canonical blob graph.
//!
//! These helpers deliberately avoid `string_agg(bytea)`.  Every payload read
//! from SPI is capped at [`READ_BLOCK_BYTES`], while metadata is fetched one
//! row (or one aggregate row) at a time.  Composite blobs are walked with a
//! bounded recursion depth and an explicit cycle check.

use md5::Md5;
use pgrx::datum::{Array, DatumWithOid, Uuid};
use pgrx::prelude::*;
use sha2::{Digest, Sha256};

const READ_BLOCK_BYTES: i64 = 1024 * 1024;
const MAX_BLOB_DEPTH: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum StorageKind {
    Inline,
    Chunked,
    Composite,
}

#[derive(Clone, Debug)]
struct BlobMeta {
    id: [u8; 32],
    size: i64,
    chunk_size: i32,
    kind: StorageKind,
}

#[derive(Clone, Debug)]
struct Extent {
    logical_offset: i64,
    source_id: [u8; 32],
    source_offset: i64,
    length: i64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct LayoutStats {
    count: i64,
    min_seq: Option<i32>,
    max_seq: Option<i32>,
    total_size: i64,
    rows_valid: bool,
}

/// Incremental SHA-256 plus MD5 state used by staged uploads.
struct Digests {
    sha256: Sha256,
    md5: Md5,
    total_size: i64,
}

impl Digests {
    fn new() -> Self {
        Self {
            sha256: Sha256::new(),
            md5: Md5::new(),
            total_size: 0,
        }
    }

    fn update(&mut self, bytes: &[u8]) {
        let amount = i64::try_from(bytes.len())
            .unwrap_or_else(|_| corrupt("one hash input block exceeds bigint"));
        self.total_size = self
            .total_size
            .checked_add(amount)
            .unwrap_or_else(|| corrupt("canonical blob size overflows bigint"));
        self.sha256.update(bytes);
        self.md5.update(bytes);
    }

    fn finish(self) -> (Vec<u8>, String, i64) {
        let sha256 = self.sha256.finalize().to_vec();
        let md5 = lower_hex(self.md5.finalize().as_slice());
        (sha256, md5, self.total_size)
    }
}

fn lower_hex(bytes: &[u8]) -> String {
    use std::fmt::Write;

    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        write!(&mut output, "{byte:02x}").expect("writing to String cannot fail");
    }
    output
}

fn corrupt(message: &str) -> ! {
    pgrx::error!("pgs3 canonical blob corruption: {message}")
}

fn invalid(message: &str) -> ! {
    pgrx::error!("invalid pgs3 hash helper input: {message}")
}

fn spi_or_error<T>(result: pgrx::spi::Result<T>, action: &str) -> T {
    match result {
        Ok(value) => value,
        Err(error) => pgrx::error!("pgs3 hash helper SPI failure while {action}: {error}"),
    }
}

fn parse_blob_id(raw: &[u8]) -> [u8; 32] {
    raw.try_into()
        .unwrap_or_else(|_| invalid("blob IDs must contain exactly 32 bytes"))
}

fn dense_layout_error(
    stats: LayoutStats,
    expected_count: i64,
    expected_size: i64,
) -> Option<&'static str> {
    if expected_count < 0 || expected_size < 0 || stats.count < 0 || stats.total_size < 0 {
        return Some("negative layout cardinality or size");
    }
    if stats.count != expected_count {
        return Some("layout row count does not match its recorded size");
    }
    if expected_count == 0 {
        if stats.min_seq.is_some() || stats.max_seq.is_some() {
            return Some("empty layout has a sequence number");
        }
    } else if stats.min_seq != Some(0) || stats.max_seq.map(i64::from) != Some(expected_count - 1) {
        return Some("layout sequence numbers are not contiguous from zero");
    }
    if stats.total_size != expected_size {
        return Some("layout byte count does not match the blob size");
    }
    if !stats.rows_valid {
        return Some("layout offsets or element sizes are invalid");
    }
    None
}

fn range_end(start: i64, length: i64, size: i64) -> Result<i64, &'static str> {
    if start < 0 || length < 0 || size < 0 {
        return Err("negative blob range or size");
    }
    let end = start
        .checked_add(length)
        .ok_or("blob range overflows bigint")?;
    if end > size {
        return Err("blob range exceeds its source blob");
    }
    Ok(end)
}

fn checked_end(start: i64, length: i64, size: i64) -> i64 {
    range_end(start, length, size).unwrap_or_else(|message| corrupt(message))
}

fn load_blob(id: &[u8; 32]) -> BlobMeta {
    let result = Spi::connect(|client| {
        let args: [DatumWithOid<'_>; 1] = [id.as_slice().into()];
        let table = client
            .select(
                "SELECT b.size, b.chunk_size, b.storage_kind, \
                        CASE WHEN b.inline IS NULL THEN NULL \
                             ELSE pg_catalog.octet_length(b.inline)::bigint END \
                   FROM pgs3.blob AS b WHERE b.sha256 = $1",
                Some(1),
                &args,
            )?
            .first();
        if table.is_empty() {
            return Ok(None);
        }
        Ok(Some((
            table.get::<i64>(1)?,
            table.get::<i32>(2)?,
            table.get::<String>(3)?,
            table.get::<i64>(4)?,
        )))
    });
    let row = spi_or_error(result, "reading blob metadata")
        .unwrap_or_else(|| corrupt("a referenced blob row is missing"));
    let (Some(size), Some(chunk_size), Some(kind), inline_size) = row else {
        corrupt("a blob metadata column is NULL");
    };
    if size < 0 || chunk_size <= 0 {
        corrupt("a blob has a negative size or non-positive chunk size");
    }
    let kind = match kind.as_str() {
        "inline" => {
            if inline_size != Some(size) {
                corrupt("inline bytes do not match the recorded blob size");
            }
            if size > i64::from(i32::MAX) - 1 {
                corrupt("an inline blob is too large for PostgreSQL substring");
            }
            StorageKind::Inline
        }
        "chunked" => {
            if inline_size.is_some() {
                corrupt("a chunked blob also contains inline bytes");
            }
            StorageKind::Chunked
        }
        "composite" => {
            if inline_size.is_some() {
                corrupt("a composite blob also contains inline bytes");
            }
            StorageKind::Composite
        }
        _ => corrupt("a blob has an unknown storage kind"),
    };
    BlobMeta {
        id: *id,
        size,
        chunk_size,
        kind,
    }
}

fn load_layout_stats(query: &str, args: &[DatumWithOid<'_>], action: &str) -> LayoutStats {
    let result = Spi::connect(|client| {
        let table = client.select(query, Some(1), args)?.first();
        Ok::<_, pgrx::spi::Error>((
            table.get::<i64>(1)?,
            table.get::<i32>(2)?,
            table.get::<i32>(3)?,
            table.get::<i64>(4)?,
            table.get::<bool>(5)?,
        ))
    });
    let (Some(count), min_seq, max_seq, Some(total_size), Some(rows_valid)) =
        spi_or_error(result, action)
    else {
        corrupt("a layout aggregate returned NULL");
    };
    LayoutStats {
        count,
        min_seq,
        max_seq,
        total_size,
        rows_valid,
    }
}

fn validate_chunk_layout(meta: &BlobMeta) -> i64 {
    let chunk_size = i64::from(meta.chunk_size);
    let expected_count = if meta.size == 0 {
        0
    } else {
        (meta.size - 1) / chunk_size + 1
    };
    let args: [DatumWithOid<'_>; 3] = [
        meta.id.as_slice().into(),
        chunk_size.into(),
        meta.size.into(),
    ];
    let stats = load_layout_stats(
        "SELECT pg_catalog.count(*)::bigint, \
                pg_catalog.min(c.seq), pg_catalog.max(c.seq), \
                coalesce( \
                    pg_catalog.sum(pg_catalog.octet_length(c.data)::bigint), 0::numeric \
                )::bigint, \
                coalesce(pg_catalog.bool_and( \
                    c.seq::bigint * $2::bigint < $3::bigint \
                    AND pg_catalog.octet_length(c.data)::bigint = \
                        least( \
                            $2::bigint, \
                            $3::bigint - c.seq::bigint * $2::bigint \
                        ) \
                ), true) \
           FROM pgs3.chunk AS c WHERE c.blob_id = $1",
        &args,
        "validating a chunk layout",
    );
    if let Some(error) = dense_layout_error(stats, expected_count, meta.size) {
        corrupt(error);
    }
    expected_count
}

fn validate_extent_layout(meta: &BlobMeta) -> i64 {
    let result = Spi::connect(|client| {
        let args: [DatumWithOid<'_>; 1] = [meta.id.as_slice().into()];
        let table = client
            .select(
                "SELECT pg_catalog.count(*)::bigint, \
                        pg_catalog.min(x.seq), pg_catalog.max(x.seq), \
                        coalesce(pg_catalog.sum(x.length), 0::numeric)::bigint, \
                        coalesce(pg_catalog.bool_and( \
                            x.logical_offset::numeric = x.expected_offset \
                            AND x.source_size IS NOT NULL \
                            AND x.source_offset <= x.source_size \
                            AND x.length <= x.source_size - x.source_offset \
                        ), true) \
                   FROM ( \
                       SELECT e.seq, e.logical_offset, e.source_offset, e.length, \
                              source.size AS source_size, \
                              coalesce( \
                                  pg_catalog.sum(e.length) OVER ( \
                                      ORDER BY e.seq \
                                      ROWS BETWEEN UNBOUNDED PRECEDING \
                                               AND 1 PRECEDING \
                                  ), 0 \
                              ) AS expected_offset \
                         FROM pgs3.blob_extent AS e \
                         LEFT JOIN pgs3.blob AS source \
                           ON source.sha256 = e.source_blob_id \
                        WHERE e.final_blob_id = $1 \
                   ) AS x",
                Some(1),
                &args,
            )?
            .first();
        Ok::<_, pgrx::spi::Error>((
            table.get::<i64>(1)?,
            table.get::<i32>(2)?,
            table.get::<i32>(3)?,
            table.get::<i64>(4)?,
            table.get::<bool>(5)?,
        ))
    });
    let (Some(count), min_seq, max_seq, Some(total_size), Some(rows_valid)) =
        spi_or_error(result, "validating an extent layout")
    else {
        corrupt("an extent aggregate returned NULL");
    };
    let stats = LayoutStats {
        count,
        min_seq,
        max_seq,
        total_size,
        rows_valid,
    };
    if let Some(error) = dense_layout_error(stats, count, meta.size) {
        corrupt(error);
    }
    count
}

fn fetch_inline_slice(id: &[u8; 32], offset: i64, length: i64) -> Vec<u8> {
    let position =
        i32::try_from(offset + 1).unwrap_or_else(|_| corrupt("inline read offset exceeds integer"));
    let length =
        i32::try_from(length).unwrap_or_else(|_| corrupt("inline read length exceeds integer"));
    let result = Spi::connect(|client| {
        let args: [DatumWithOid<'_>; 3] = [id.as_slice().into(), position.into(), length.into()];
        client
            .select(
                "SELECT pg_catalog.substring(b.inline, $2::integer, $3::integer) \
                   FROM pgs3.blob AS b WHERE b.sha256 = $1",
                Some(1),
                &args,
            )?
            .first()
            .get_one::<Vec<u8>>()
    });
    spi_or_error(result, "reading bounded inline bytes")
        .unwrap_or_else(|| corrupt("inline bytes disappeared while hashing"))
}

fn fetch_chunk_slice(id: &[u8; 32], seq: i32, offset: i64, length: i64) -> Vec<u8> {
    let position =
        i32::try_from(offset + 1).unwrap_or_else(|_| corrupt("chunk read offset exceeds integer"));
    let length =
        i32::try_from(length).unwrap_or_else(|_| corrupt("chunk read length exceeds integer"));
    let result = Spi::connect(|client| {
        let args: [DatumWithOid<'_>; 4] = [
            id.as_slice().into(),
            seq.into(),
            position.into(),
            length.into(),
        ];
        client
            .select(
                "SELECT pg_catalog.substring(c.data, $3::integer, $4::integer) \
                   FROM pgs3.chunk AS c \
                  WHERE c.blob_id = $1 AND c.seq = $2",
                Some(1),
                &args,
            )?
            .first()
            .get_one::<Vec<u8>>()
    });
    spi_or_error(result, "reading bounded chunk bytes")
        .unwrap_or_else(|| corrupt("a chunk disappeared while hashing"))
}

fn load_extent(id: &[u8; 32], seq: i32) -> Extent {
    let result = Spi::connect(|client| {
        let args: [DatumWithOid<'_>; 2] = [id.as_slice().into(), seq.into()];
        let table = client
            .select(
                "SELECT e.logical_offset, e.source_blob_id, \
                        e.source_offset, e.length \
                   FROM pgs3.blob_extent AS e \
                  WHERE e.final_blob_id = $1 AND e.seq = $2",
                Some(1),
                &args,
            )?
            .first();
        if table.is_empty() {
            return Ok(None);
        }
        Ok(Some((
            table.get::<i64>(1)?,
            table.get::<Vec<u8>>(2)?,
            table.get::<i64>(3)?,
            table.get::<i64>(4)?,
        )))
    });
    let row = spi_or_error(result, "reading an extent")
        .unwrap_or_else(|| corrupt("an extent disappeared while hashing"));
    let (Some(logical_offset), Some(source_id), Some(source_offset), Some(length)) = row else {
        corrupt("an extent column is NULL");
    };
    Extent {
        logical_offset,
        source_id: parse_blob_id(&source_id),
        source_offset,
        length,
    }
}

fn emit_bounded_cell<F>(
    id: &[u8; 32],
    seq: Option<i32>,
    mut offset: i64,
    mut length: i64,
    emit: &mut F,
) where
    F: FnMut(&[u8]),
{
    while length > 0 {
        let amount = length.min(READ_BLOCK_BYTES);
        let bytes = match seq {
            Some(seq) => fetch_chunk_slice(id, seq, offset, amount),
            None => fetch_inline_slice(id, offset, amount),
        };
        if i64::try_from(bytes.len()).ok() != Some(amount) {
            corrupt("a bounded payload read returned fewer bytes than requested");
        }
        emit(&bytes);
        offset = offset
            .checked_add(amount)
            .unwrap_or_else(|| corrupt("payload read offset overflows bigint"));
        length -= amount;
    }
}

fn stream_blob_range<F>(
    id: &[u8; 32],
    start: i64,
    length: i64,
    path: &mut Vec<[u8; 32]>,
    emit: &mut F,
) where
    F: FnMut(&[u8]),
{
    if path.len() >= MAX_BLOB_DEPTH {
        corrupt("blob extent nesting exceeds 64 levels");
    }
    if path.contains(id) {
        corrupt("blob extent graph contains a cycle");
    }
    let meta = load_blob(id);
    let end = checked_end(start, length, meta.size);
    path.push(*id);

    match meta.kind {
        StorageKind::Inline => emit_bounded_cell(id, None, start, length, emit),
        StorageKind::Chunked => {
            validate_chunk_layout(&meta);
            if length > 0 {
                let chunk_size = i64::from(meta.chunk_size);
                let first = start / chunk_size;
                let last = (end - 1) / chunk_size;
                for seq64 in first..=last {
                    let seq = i32::try_from(seq64)
                        .unwrap_or_else(|_| corrupt("chunk sequence exceeds integer"));
                    let chunk_start = seq64
                        .checked_mul(chunk_size)
                        .unwrap_or_else(|| corrupt("chunk offset overflows bigint"));
                    let from = start.max(chunk_start);
                    let to = end.min(
                        chunk_start
                            .checked_add(chunk_size)
                            .unwrap_or_else(|| corrupt("chunk end overflows bigint")),
                    );
                    emit_bounded_cell(id, Some(seq), from - chunk_start, to - from, emit);
                }
            }
        }
        StorageKind::Composite => {
            let count = validate_extent_layout(&meta);
            for seq64 in 0..count {
                let seq = i32::try_from(seq64)
                    .unwrap_or_else(|_| corrupt("extent sequence exceeds integer"));
                let extent = load_extent(id, seq);
                let extent_end = checked_end(extent.logical_offset, extent.length, meta.size);
                if extent.length == 0 || extent.logical_offset >= end || extent_end <= start {
                    continue;
                }
                let from = start.max(extent.logical_offset);
                let to = end.min(extent_end);
                let source_start = extent
                    .source_offset
                    .checked_add(from - extent.logical_offset)
                    .unwrap_or_else(|| corrupt("source extent offset overflows bigint"));
                stream_blob_range(&extent.source_id, source_start, to - from, path, emit);
            }
        }
    }

    path.pop();
}

/// Read a complete canonical blob, independently verify its content-addressed
/// identity, and forward its bytes to the caller's incremental digest.
fn stream_verified_blob<F>(id: &[u8; 32], emit: &mut F) -> i64
where
    F: FnMut(&[u8]),
{
    let meta = load_blob(id);
    let mut verifier = Sha256::new();
    let mut emitted = 0_i64;
    let mut path = Vec::with_capacity(8);
    stream_blob_range(id, 0, meta.size, &mut path, &mut |bytes| {
        verifier.update(bytes);
        let amount = i64::try_from(bytes.len())
            .unwrap_or_else(|_| corrupt("one verified blob block exceeds bigint"));
        emitted = emitted
            .checked_add(amount)
            .unwrap_or_else(|| corrupt("verified blob size overflows bigint"));
        emit(bytes);
    });
    if emitted != meta.size {
        corrupt("a blob traversal did not read its complete logical size");
    }
    let digest = verifier.finalize();
    if digest.as_slice() != id {
        corrupt("canonical payload SHA-256 does not match its blob ID");
    }
    emitted
}

fn load_upload(upload_id: Uuid) -> (bool, String) {
    let result = Spi::connect(|client| {
        let args: [DatumWithOid<'_>; 1] = [upload_id.into()];
        let table = client
            .select(
                "SELECT u.multipart, u.state \
                   FROM pgs3.upload AS u WHERE u.upload_id = $1",
                Some(1),
                &args,
            )?
            .first();
        if table.is_empty() {
            return Ok(None);
        }
        Ok(Some((table.get::<bool>(1)?, table.get::<String>(2)?)))
    });
    let row = spi_or_error(result, "reading an upload")
        .unwrap_or_else(|| invalid("the upload ID does not exist"));
    let (Some(multipart), Some(state)) = row else {
        corrupt("an upload metadata column is NULL");
    };
    if state != "pending" && state != "completing" {
        corrupt("an upload has an unknown state");
    }
    (multipart, state)
}

fn upload_layout(upload_id: Uuid, part_number: i32) -> LayoutStats {
    let args: [DatumWithOid<'_>; 2] = [upload_id.into(), part_number.into()];
    load_layout_stats(
        "SELECT pg_catalog.count(*)::bigint, \
                pg_catalog.min(c.seq), pg_catalog.max(c.seq), \
                coalesce(pg_catalog.sum(c.size), 0::numeric)::bigint, \
                coalesce(pg_catalog.bool_and(c.size >= 0), true) \
           FROM pgs3.upload_chunk AS c \
          WHERE c.upload_id = $1 AND c.part_number = $2",
        &args,
        "validating an upload chunk layout",
    )
}

fn load_upload_chunk(upload_id: Uuid, part_number: i32, seq: i32) -> ([u8; 32], i64) {
    let result = Spi::connect(|client| {
        let args: [DatumWithOid<'_>; 3] = [upload_id.into(), part_number.into(), seq.into()];
        let table = client
            .select(
                "SELECT c.blob_id, c.size \
                   FROM pgs3.upload_chunk AS c \
                  WHERE c.upload_id = $1 \
                    AND c.part_number = $2 AND c.seq = $3",
                Some(1),
                &args,
            )?
            .first();
        if table.is_empty() {
            return Ok(None);
        }
        Ok(Some((table.get::<Vec<u8>>(1)?, table.get::<i64>(2)?)))
    });
    let row = spi_or_error(result, "reading an upload chunk")
        .unwrap_or_else(|| corrupt("an upload chunk disappeared while hashing"));
    let (Some(blob_id), Some(size)) = row else {
        corrupt("an upload chunk column is NULL");
    };
    if size < 0 {
        corrupt("an upload chunk has a negative size");
    }
    (parse_blob_id(&blob_id), size)
}

#[pg_schema]
mod pgs3 {
    use super::*;

    /// Incrementally hash the canonical blobs staged for one upload part.
    #[pg_extern(stable, strict, security_definer)]
    #[search_path(pg_catalog, pgs3)]
    fn hash_upload_part(
        upload_id: Uuid,
        part_number: i32,
    ) -> TableIterator<
        'static,
        (
            name!(sha256, Vec<u8>),
            name!(md5, String),
            name!(total_size, i64),
        ),
    > {
        if !(0..=10_000).contains(&part_number) {
            invalid("part_number must be between 0 and 10000");
        }
        let (multipart, _) = load_upload(upload_id);
        if multipart == (part_number == 0) {
            invalid("part_number 0 is only valid for a non-multipart streaming PUT");
        }

        let stats = upload_layout(upload_id, part_number);
        if part_number > 0 && stats.count == 0 {
            invalid("a multipart part must contain at least one staged chunk");
        }
        if let Some(error) = dense_layout_error(stats, stats.count, stats.total_size) {
            corrupt(error);
        }

        let mut digests = Digests::new();
        for seq64 in 0..stats.count {
            let seq = i32::try_from(seq64)
                .unwrap_or_else(|_| corrupt("upload chunk sequence exceeds integer"));
            let (blob_id, recorded_size) = load_upload_chunk(upload_id, part_number, seq);
            let actual_size = stream_verified_blob(&blob_id, &mut |bytes| digests.update(bytes));
            if actual_size != recorded_size {
                corrupt("an upload chunk size does not match its canonical blob");
            }
        }
        let result = digests.finish();
        if result.2 != stats.total_size {
            corrupt("the streamed upload size changed while hashing");
        }
        TableIterator::new(std::iter::once(result))
    }

    /// Incrementally hash a sequence of complete canonical blobs.
    #[pg_extern(stable, strict, security_definer)]
    #[search_path(pg_catalog, pgs3)]
    fn hash_blob_sequence(
        blob_ids: Array<'_, &[u8]>,
    ) -> TableIterator<'static, (name!(sha256, Vec<u8>), name!(total_size, i64))> {
        // `Array<'_, &[u8]>` borrows PostgreSQL-owned memory.  Every blob walk
        // below opens nested SPI connections, whose memory-context teardown
        // must not leave the array iterator pointing at released storage.
        // Copy the small fixed-width identifiers before the first SPI call.
        // Multipart completion can otherwise dereference stale array memory
        // after hashing its first part and crash the whole postmaster.
        let blob_ids: Vec<[u8; 32]> = blob_ids
            .iter()
            .map(|raw| {
                let raw = raw.unwrap_or_else(|| invalid("blob ID arrays cannot contain NULL"));
                parse_blob_id(raw)
            })
            .collect();
        let mut sha256 = Sha256::new();
        let mut total_size = 0_i64;
        for blob_id in &blob_ids {
            let size = stream_verified_blob(blob_id, &mut |bytes| sha256.update(bytes));
            total_size = total_size
                .checked_add(size)
                .unwrap_or_else(|| corrupt("blob sequence size overflows bigint"));
        }
        TableIterator::new(std::iter::once((sha256.finalize().to_vec(), total_size)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn incremental_digests_match_known_vectors() {
        let mut digests = Digests::new();
        digests.update(b"a");
        digests.update(b"bc");
        let (sha256, md5, size) = digests.finish();
        assert_eq!(
            lower_hex(&sha256),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(md5, "900150983cd24fb0d6963f7d28e17f72");
        assert_eq!(size, 3);
    }

    #[test]
    fn dense_layout_validation_rejects_holes_and_bad_sizes() {
        let valid = LayoutStats {
            count: 3,
            min_seq: Some(0),
            max_seq: Some(2),
            total_size: 12,
            rows_valid: true,
        };
        assert_eq!(dense_layout_error(valid, 3, 12), None);

        let mut invalid = valid;
        invalid.min_seq = Some(1);
        assert!(dense_layout_error(invalid, 3, 12).is_some());
        invalid = valid;
        invalid.total_size = 11;
        assert!(dense_layout_error(invalid, 3, 12).is_some());
        invalid = valid;
        invalid.rows_valid = false;
        assert!(dense_layout_error(invalid, 3, 12).is_some());
    }

    #[test]
    fn checked_ranges_reject_overflow_and_out_of_bounds() {
        assert_eq!(range_end(2, 3, 5), Ok(5));
        assert_eq!(
            range_end(i64::MAX, 1, i64::MAX),
            Err("blob range overflows bigint")
        );
        assert_eq!(
            range_end(4, 2, 5),
            Err("blob range exceeds its source blob")
        );
    }
}
