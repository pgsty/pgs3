# Performance results

## Status: complete curves; gates 12--13 and 16 fail, gate 14 passes

The final golden-image, default-4 MiB-chunk HTTP sweep completed against pgs3
and same-host MinIO with zero request or integrity errors. Gates 14 and 17 pass;
fixed small-object gates 12--13 fail. Current golden-image SQL scale passes both
LIST thresholds but fork takes 1944.071 ms, so gate 16 fails.

Evidence: final HTTP [`manifest`](../artifacts/acceptance/20260831T065555Z-http-benchmark-acceptance-pg17-91774/manifest.json),
[`summary`](../artifacts/acceptance/20260831T065555Z-http-benchmark-acceptance-pg17-91774/benchmark/summary.json),
[`environment`](../artifacts/acceptance/20260831T065555Z-http-benchmark-acceptance-pg17-91774/benchmark/environment.json),
and [`raw samples`](../artifacts/acceptance/20260831T065555Z-http-benchmark-acceptance-pg17-91774/benchmark/raw-samples.jsonl);
golden-image [`scale`](../artifacts/acceptance/20260831T065441Z-scale-pg17-90791/manifest.json);
and same-final-source, pre-golden-image
[`scale iteration`](../artifacts/acceptance/20260831T063544Z-scale-pg17-62527/manifest.json).

## Environment and tuning

| Field | Recorded value |
| --- | --- |
| UTC interval | 2026-08-31 06:56:08--06:56:51 |
| Workspace | unborn/dirty; SHA-256 `780ea7bb4c2a852c60bec9b22e637ec051ddd43ed0fa21015d0107b166fd09b9` |
| Host / Docker | Apple M5 Max, 18 CPUs/128 GiB; Docker Desktop 29.4.1, 16 vCPUs/about 64 GiB, arm64 |
| Baseline differences | power-safe NVMe and hot-buffer residency not proven; Docker physical-core topology not verified |
| PostgreSQL | 17.10; image `sha256:270f9b60c903bac41b8587d5e912525cc87aa8381e3c52ca5bcc1206d7da4eda` |
| pgs3 | 16 workers, 1 GiB shared buffers, 64 KiB direct threshold, default 4 MiB staged chunk size |
| Durability/checkpoints | fsync/full-page-writes/synchronous-commit on; `max_wal_size=4GB`, `checkpoint_timeout=30min`; no workload checkpoint |
| MinIO | `RELEASE.2026-08-04T00-00-00Z`, pinned one-server/one-volume image |
| Workload | persistent HTTP/1.1 SigV4, deterministic distinct payloads, three warmups, zero retries |

No normalization was applied. HTTP honors `pgs3.chunk_size` for staged PUT and
snapshots it per request across SIGHUP. D027 removes the ordinary staged
PutObject completion reread only after the restricted worker and PostgreSQL have
bound an exact ordered canonical chunk manifest. Earlier one-request diagnostic
samples measured 119.24 MiB/s at 2 MiB, 154.92 MiB/s at 4 MiB, and about
32 MiB/s at an 8 MiB allocation/storage cliff. The complete 4 MiB-default sweep
now measures 167.894 MiB/s for the required 8 MiB PUT and is authoritative.

## Complete object-size sweep

Milliseconds, operations/s, and MiB/s; nearest-rank percentiles.

| Size | System | PUT p50 | PUT p95 | PUT p99 | PUT ops/s | PUT MiB/s | GET p50 | GET p95 | GET p99 | GET ops/s | GET MiB/s | Errors |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 4 KiB | pgs3 | 5.779 | 15.652 | 27.553 | 1555.986 | 6.078 | 2.863 | 9.984 | 14.574 | 4065.195 | 15.880 | 0 |
| 4 KiB | MinIO | 9.130 | 14.565 | 16.995 | 1662.550 | 6.494 | 2.815 | 9.154 | 12.537 | 4137.809 | 16.163 | 0 |
| 16 KiB | pgs3 | 4.664 | 9.894 | 17.896 | 2443.748 | 38.184 | 3.342 | 8.501 | 11.448 | 3989.933 | 62.343 | 0 |
| 16 KiB | MinIO | 9.007 | 14.019 | 15.997 | 1701.106 | 26.580 | 5.218 | 13.350 | 18.613 | 2577.770 | 40.278 | 0 |
| 65,535 B | pgs3 | 4.694 | 15.049 | 23.559 | 1932.459 | 120.777 | 3.328 | 8.549 | 11.280 | 4055.658 | 253.475 | 0 |
| 65,535 B | MinIO | 10.669 | 15.227 | 17.362 | 1456.363 | 91.021 | 3.890 | 9.726 | 13.202 | 3530.574 | 220.658 | 0 |
| 64 KiB | pgs3 | 2.731 | 9.421 | 13.103 | 3646.459 | 227.904 | 2.150 | 5.507 | 7.440 | 6154.713 | 384.670 | 0 |
| 64 KiB | MinIO | 9.038 | 12.999 | 15.556 | 1692.439 | 105.777 | 3.024 | 7.364 | 9.759 | 4575.654 | 285.978 | 0 |
| 65,537 B | pgs3 | 8.159 | 15.365 | 23.382 | 1328.234 | 83.016 | 3.523 | 9.673 | 14.297 | 3631.641 | 226.981 | 0 |
| 65,537 B | MinIO | 10.106 | 15.430 | 19.618 | 1495.458 | 93.468 | 3.105 | 7.470 | 10.317 | 4467.902 | 279.248 | 0 |
| 256 KiB | pgs3 | 8.562 | 25.839 | 41.856 | 1033.729 | 258.432 | 2.811 | 5.563 | 7.178 | 5029.700 | 1257.425 | 0 |
| 256 KiB | MinIO | 8.993 | 14.267 | 16.575 | 1661.785 | 415.446 | 2.450 | 5.725 | 6.739 | 5501.952 | 1375.488 | 0 |
| 1 MiB | pgs3 | 31.891 | 89.721 | 96.305 | 284.384 | 284.384 | 5.321 | 23.999 | 25.755 | 1802.875 | 1802.875 | 0 |
| 1 MiB | MinIO | 13.847 | 22.077 | 25.940 | 1054.880 | 1054.880 | 4.552 | 9.043 | 11.373 | 2927.418 | 2927.418 | 0 |
| 4 MiB | pgs3 | 42.862 | 76.687 | 90.170 | 64.593 | 258.372 | 8.774 | 15.064 | 15.291 | 369.104 | 1476.415 | 0 |
| 4 MiB | MinIO | 22.301 | 26.624 | 26.650 | 176.297 | 705.186 | 3.305 | 4.471 | 4.651 | 1093.349 | 4373.397 | 0 |
| 8 MiB | pgs3 | 47.400 | 56.605 | 56.605 | 20.987 | 167.894 | 39.466 | 41.363 | 41.363 | 99.145 | 793.157 | 0 |
| 8 MiB | MinIO | 20.826 | 21.027 | 21.027 | 49.161 | 393.291 | 5.912 | 9.261 | 9.261 | 533.925 | 4271.401 | 0 |
| 16 MiB | pgs3 | 90.509 | 102.809 | 102.809 | 10.647 | 170.348 | 51.463 | 73.798 | 73.798 | 31.641 | 506.251 | 0 |
| 16 MiB | MinIO | 35.795 | 38.154 | 38.154 | 27.601 | 441.615 | 9.964 | 11.217 | 11.217 | 191.992 | 3071.865 | 0 |
| 64 MiB | pgs3 | 395.761 | 421.511 | 421.511 | 2.447 | 156.602 | 444.676 | 511.342 | 511.342 | 2.087 | 133.553 | 0 |
| 64 MiB | MinIO | 196.367 | 198.684 | 198.684 | 5.062 | 323.951 | 50.358 | 73.855 | 73.855 | 15.756 | 1008.384 | 0 |

## Acceptance checks

| Requirement | Target | Final result | Status |
| --- | ---: | ---: | --- |
| Gate 12 small GET p50 | <0.5 ms | max 3.341708 ms | FAIL |
| Gate 12 small GET rate | >=30,000/s | min 3989.933/s | FAIL |
| Gate 13 small PUT rate | >=5,000/s | min 1555.986/s | FAIL |
| Gate 14 8 MiB PUT | >=150 MiB/s | 167.894 MiB/s, p50 47.399667 ms, client concurrency 1 | PASS |
| Gate 15 LIST / delimiter LIST | <5 / <10 ms | 2.358 / 9.487 ms | PASS |
| Gate 16 fork 100k | <1 s | 1944.071 ms | FAIL |
| Gate 17 complete comparison | complete | 11 sizes, both systems, zero errors | PASS |

Gate 14 used one persistent client connection against a 16-worker listener pool.
Sequential keep-alive keeps that socket on one accepting worker, although the
evidence does not record the worker PID alongside every sample.

The golden-image LIST plans touch 1,020/5,139 shared blocks and emit zero WAL.
Fork correctness, refcounts, and independent mutations pass; fork emits
154,178,689 WAL bytes. The same workspace digest on pre-golden image
`sha256:3a83ef8c...` measured fork/LIST/delimiter at
865.495/1.086/5.238 ms, all PASS. That iteration demonstrates that the materialized
DML CTE and `pgs3.blob` fillfactor 80 optimization can meet the gate, but the
golden-image 1944.071 ms result is authoritative and keeps gate 16 failed.

## Findings

- D026's boundary remains visible: 64 KiB direct PUT p50 is 2.731 ms versus
  8.159 ms one byte above on the staged path.
- D027 plus the 4 MiB default raises the required 8 MiB PUT from the earlier
  failed 29.436 MiB/s observation to 167.894 MiB/s on the final sweep. This
  passes gate 14 without changing durability settings.
- `fork_bucket` feeds inserted blob IDs through one materialized DML CTE into a
  set-wise refcount update, and `pgs3.blob` uses fillfactor 80. Correctness passes,
  but final-image timing remains unstable and fails gate 16.
- A `CACHE 1024` experiment on `object_version_id_seq` was rejected after it
  broke externally observed version ordering in one selected Ceph case
  (194/195). The final schema retains PostgreSQL's default `CACHE 1`, and the
  golden Ceph run passes 195/195.
- Repeat on a documented power-safe local NVMe reference host before production
  sizing; never normalize away these Docker Desktop results.
