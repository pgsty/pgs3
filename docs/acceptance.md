# Acceptance evidence

This is the release gate for the 17 numbered acceptance requirements. A source
file or unit test is not sufficient evidence for an end-to-end requirement.
Every measured run must record the Git revision (or dirty-tree digest), exact
command, client/server versions, raw output, and exit status under
`artifacts/acceptance/<run-id>/`. Generated artifacts are not silently promoted
to documentation; the reviewed summary is committed here and raw artifacts are
kept with the release record.

Status values are `PASS`, `FAIL`, `BLOCKED`, and `NOT RUN`. `PASS` means the
manifest's recorded tree was exercised at the scale stated by the specification;
it is not automatically fresh for later source changes. The manifests below cover
the current extension images.

## Release matrix

| # | Gate | Reproducible entry point | Current status | Current evidence |
| ---: | --- | --- | --- | --- |
| 1 | aws CLI (`s3` and `s3api`), rclone sync/check, boto3, s3fs-fuse vim/grep/find, DuckDB httpfs | `make client-test PG_MAJOR=17` | PASS | Every client step, including two-page ListParts and real FUSE, passed in [`clients-pg17-72577`](../artifacts/acceptance/20260831T064443Z-clients-pg17-72577/manifest.json). The full PG18 matrix also passes in [`clients-pg18-71442`](../artifacts/acceptance/20260831T064421Z-clients-pg18-71442/manifest.json). |
| 2 | 100 MiB aws CLI multipart upload, S3 multipart ETag, rclone check | `make client-test PG_MAJOR=17` | PASS | The 13-part object had ETag `cae9a4ed1e7ce2b3cd57e4d4e52555de-13`; upload/download SHA-256 and `cmp` matched, and rclone reported one match and zero differences in the same client manifest. |
| 3 | At least 150 ceph s3-tests with per-case pass/fail/skip reasons; all in-scope core cases pass | `make ceph-test PG_MAJOR=17` | PASS | Pinned upstream commit `5522d1c`: fixed candidate 209, exact source-audited exclusions 14, selected/executed/passed 195, and zero failure/error/skip/not-run in [`ceph-s3-tests-pg17-74469`](../artifacts/acceptance/20260831T064550Z-ceph-s3-tests-pg17-74469/manifest.json). |
| 4 | 20 rounds of 50-way `If-None-Match: *` and `If-Match`, exactly one success per round | `make sql-test PG_MAJOR=17` | PASS | Golden-image PG17 and PG18 SQL suites passed, including exactly one success in every required round: [`PG17`](../artifacts/acceptance/20260831T065107Z-sql-semantic-pg17-83057/manifest.json), [`PG18`](../artifacts/acceptance/20260831T065126Z-sql-semantic-pg18-83550/manifest.json). |
| 5 | 100 identical small and large uploads deduplicate to one blob; deletion plus GC reaches zero blobs/chunks | `make sql-test PG_MAJOR=17` | PASS | The same current PG17/PG18 SQL manifests cover 100 uploads of each representation, Copy/Fork refcounts, deletion, and GC-to-zero. |
| 6 | SIGKILL during upload; recovery exposes no partial object, preserves committed objects, and GC removes pending data | `make crash-test PG_MAJOR=17` | PASS | Committed SHA, partial invisibility, surviving pending state, exact post-GC counts, and post-GC readability passed in [`reliability-all-pg17-80047`](../artifacts/acceptance/20260831T065006Z-reliability-all-pg17-80047/manifest.json); its final redaction audit covered all 107 evidence files. |
| 7 | Fork 100,000 objects in under one second; independent later mutations; zero payload copy | `make scale-test PG_MAJOR=17` | FAIL | Sharing/refcount reconciliation, result shape, and independent later writes passed, but golden-image fork took 1944.071 ms; see [`scale-pg17-90791`](../artifacts/acceptance/20260831T065441Z-scale-pg17-90791/manifest.json). |
| 8 | Two-tenant isolation for LIST/HEAD/object/presign plus bad signature, expiry, and body-tamper rejection | `make http-smoke PG_MAJOR=17` | PASS | Header/presigned auth, cross-tenant LIST/HEAD/GET/presign invisibility, invalid signature, expiry, and body tampering pass in the current stdlib/client runs. The pinned Ceph matrix adds invalid-auth and cross-tenant Copy coverage. |
| 9 | Malformed header/XML/body/framing corpus does not kill a worker or restart PostgreSQL | `make robustness-test PG_MAJOR=17 && make fuzz-test PG_MAJOR=17` | PASS | All seven fixed cases pass in [`robustness-83397`](../artifacts/acceptance/20260831T065124Z-http-robustness-pg17-83397/manifest.json); all 24 deterministic fuzz cases preserve exact postmaster/worker/container identities and a signed sentinel in [`fuzz-84795`](../artifacts/acceptance/20260831T065154Z-fuzz-malformed-pg17-84795/manifest.json). |
| 10 | Hot standby serves GET/LIST and returns a bounded S3 error for writes | `make standby-test PG_MAJOR=17` | PASS | Current reliability evidence proves exact-SHA GET/ListObjectsV2 and HTTP 503/S3 `ServiceUnavailable` with `bytes_sent=0`, no partial object, and process survival. |
| 11 | PostgreSQL stops within five seconds; SIGHUP applies new GUC values | `make lifecycle-test PG_MAJOR=17` | PASS | Current reliability evidence measures target shutdown at 276 ms and proves worker convergence, listener move, new-endpoint GET, and reloaded 250 ms timeout returning `SlowDown` in 0.261 s. |
| 12 | GET <=64 KiB: p50 under 0.5 ms and aggregate at least 30,000/s | `make benchmark-test PG_MAJOR=17` | FAIL | Final 4 MiB-default sweep: worst p50 3.341708 ms and minimum small-object GET rate 3989.933/s. See [`benchmark-91774`](../artifacts/acceptance/20260831T065555Z-http-benchmark-acceptance-pg17-91774/manifest.json). |
| 13 | PUT <=64 KiB: aggregate at least 5,000/s | `make benchmark-test PG_MAJOR=17` | FAIL | Minimum small-object PUT rate was 1555.986/s; zero request/integrity errors. |
| 14 | 8 MiB PUT: one worker at least 150 MiB/s | `make benchmark-test PG_MAJOR=17` | PASS | One concurrent client/request measured 167.894 MiB/s at p50 47.399667 ms with the 4 MiB staged-chunk default. The harness uses one persistent connection, but worker PID affinity is not separately recorded. |
| 15 | LIST 1,000 under 5 ms; delimiter LIST of 1,000 child prefixes in a 1M-key bucket under 10 ms | `make scale-test PG_MAJOR=17` | PASS | Golden image: ordinary LIST 2.358 ms/1,020 shared blocks and delimiter LIST 9.487 ms/5,139 shared blocks; result-shape and zero-WAL checks passed. |
| 16 | Fork 100,000 objects under one second | `make scale-test PG_MAJOR=17` | FAIL | Golden image: 1944.071 ms, with correctness passing. A same-final-source, pre-golden-image iteration measured 865.495 ms, while the golden run still fails; this is severe host/I/O variance, not a stable pass. |
| 17 | 4 KiB--64 MiB PUT/GET curves versus same-host MinIO | `make benchmark-test PG_MAJOR=17` | PASS | All 11 sizes ran against both systems with complete raw samples, verified GET content, and zero errors. See [`perf.md`](perf.md) and [`summary.json`](../artifacts/acceptance/20260831T065555Z-http-benchmark-acceptance-pg17-91774/benchmark/summary.json). |

`make reliability-test PG_MAJOR=17` runs crash, fast-stop, reload, and standby.
`make lifecycle-test` runs only fast-stop and reload, while the individual targets
shown above run one scenario. Every runtime invocation performs the offline
reliability checks first. Scale, robustness, fuzz, and benchmark harnesses have Make
targets and produce isolated run-labeled evidence. The release matrix remains
open because passing functional coverage does not waive failed performance gates.

## Non-numbered release gates

The following gates come from the hard constraints and deliverables and are
required in addition to the numbered matrix:

- the reviewed package-backed PG17 image
  `sha256:270f9b60c903bac41b8587d5e912525cc87aa8381e3c52ca5bcc1206d7da4eda`
  and PG18 image
  `sha256:0bc9f5a9846b3c460ef5bdf15424701d9edf942badaec6ec00ad325b1ad6f636`
  install and pass their SQL/HTTP gates (PG16 remains best effort);
- the real frozen-fixture `0.1.0 -> 0.1.1` transition and direct 0.1.1 install
  both pass on [`PG17`](../artifacts/acceptance/20260831T063728Z-extension-upgrade-pg17-65725/manifest.json)
  and [`PG18`](../artifacts/acceptance/20260831T063921Z-extension-upgrade-pg18-67508/manifest.json),
  including rich data/RLS/refcount/catalog parity;
- one command runs every mandatory suite and fails when a required tool or
  result is absent;
- the pgrx package contains the control file, generated install SQL, and shared
  library; the repository/release bundle separately contains documentation and
  the upgrade/migration policy;
- `cargo fmt`, feature-matrix `cargo check`, clippy, and Rust unit tests pass;
- no test uses a client-provided checksum as a content-address lookup key;
- raw secrets, signatures, SQL text, and cross-tenant identifiers do not appear
  in client errors, metrics labels, or ordinary logs.

## Evidence scope and freshness

The PG17 stdlib HTTP probe is a live package/install test, not only a protocol
unit test. It covers full-hash header auth, `UNSIGNED-PAYLOAD` presigning,
`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`,
`STREAMING-UNSIGNED-PAYLOAD-TRAILER`, checksum/signature tampering, and tenant
invisibility. Current PG17 and PG18 client manifests separately exercise aws CLI,
rclone, boto3, ListParts paging, s3fs, and DuckDB.

The earlier [`clients-pg17-20260831`](../artifacts/acceptance/clients-pg17-20260831/manifest.json)
attempt stopped at a Docker Hub token timeout and did not exercise clients. The
later `004926Z` run exposed a real multipart `SIGSEGV`. It remains useful defect
  history, but current PG17 `064443Z` and PG18 `064421Z` matrices supersede it: the
100 MiB case and every remaining client pass without a postmaster restart.

The Ceph selection is intentionally strict. The 14 exclusions are exactly two
Ceph-only unordered-list cases, two ACL-dependent owner-list cases, four non-AWS
PUT-condition variants, one cross-tenant 403 assertion that conflicts with
non-disclosure, one us-east-1 fixture mismatch, and four repeat-completion or
duplicate-part-number cases. The source anchors and per-case reasons are retained
in the run's
[`suite-manifest.json`](../artifacts/acceptance/20260831T064550Z-ceph-s3-tests-pg17-74469/ceph/suite-manifest.json);
no selected failure, error, or skip was reclassified as an exclusion.

Multipart SHA256 `COMPOSITE` checksum publication is covered. As documented in
D024, automatic non-SHA multipart selection is accepted for required-client
compatibility and supplied part checksums are verified, but a final non-SHA
composite is not yet validated or stored.

All manifests name an exact dirty-worktree SHA-256 and image identity. The current
extension source—including D025--D029, keep-alive, sealed staged PUT, the 4 MiB
default, the real upgrade path, GET/ListParts, dynamic stop, and fuzz hardening—is
packaged in PG17 image `270f9b60...` and PG18 image `0bc9f5a9...`.
SQL/client/upgrade/Ceph/reliability/robustness/fuzz/scale/benchmark runs above
exercise those images. The final manifests share workspace digest
`780ea7bb4c2a852c60bec9b22e637ec051ddd43ed0fa21015d0107b166fd09b9`;
later documentation and cleanup-harness-only edits do not change the recorded
extension binaries.

The final tuned benchmark and PG18 client matrix use that same recorded source
boundary. A rejected `CACHE 1024` sequence experiment failed one selected Ceph
version-order case (194/195) in
[`ceph-53755`](../artifacts/acceptance/20260831T063034Z-ceph-s3-tests-pg17-53755/manifest.json);
the final schema retains sequence `CACHE 1`, and the golden-image Ceph run returns
to 195/195. Earlier harness/environment failures remain defect history, not final
product gates.
