#!/usr/bin/env bash
# shellcheck disable=SC2034 # state is consumed by the sourced harness and EXIT trap
set -Eeuo pipefail

benchmark_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${benchmark_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local benchmark harness
source "${benchmark_dir}/harness_lib.sh"

pg_major=${PG_MAJOR:-17}
profile=acceptance
skip_build=${PGS3_SKIP_BUILD:-0}
static_only=0
requested_run_id=''
environment_note=${PGS3_BENCH_ENVIRONMENT_NOTE:-}

pgs3_image=${PGS3_BENCH_PGS3_IMAGE:-pgs3-test:pg${pg_major}}
client_image=${PGS3_BENCH_CLIENT_IMAGE:-pgs3-client-test:20250226}
minio_image=${PGS3_BENCH_MINIO_IMAGE:-pgsty/minio@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372}

smoke_sizes=${PGS3_BENCH_SMOKE_SIZES:-4096,65535,65536,65537,262144}
smoke_samples=${PGS3_BENCH_SMOKE_SAMPLES:-3}
smoke_warmups=${PGS3_BENCH_SMOKE_WARMUPS:-1}
smoke_concurrency=${PGS3_BENCH_SMOKE_CONCURRENCY:-2}

usage() {
    cat <<'USAGE'
usage: tests/benchmark/run.sh [--profile acceptance|smoke] [--pg 17|18]
                              [--skip-build] [--static-only] [--run-id ID]
                              [--environment-note TEXT]

The acceptance profile is fixed: 4 KiB through 64 MiB, including 65535/65536/
65537-byte boundary cases, deterministic incompressible bodies, 16 pgs3 workers,
and the published thresholds for requirements 12-14 and 17. Threshold misses
return nonzero and remain FAIL evidence.

The smoke profile is only a harness check.  Its sizes/sample counts may be reduced
through PGS3_BENCH_SMOKE_* variables, but requirements 12-14 and 17 are always
reported NOT_RUN.

MinIO must be an immutable image reference containing @sha256:<64 hex>.  The
default is pgsty/minio RELEASE.2026-08-04 pinned by digest.  Runtime containers
always use --pull never.  The pgs3 image is built from the current workspace by
default; --skip-build reuses and records an existing local image.
USAGE
}

while (($#)); do
    case $1 in
        --profile)
            profile=${2:?--profile requires a value}
            shift 2
            ;;
        --pg)
            pg_major=${2:?--pg requires a value}
            shift 2
            ;;
        --skip-build)
            skip_build=1
            shift
            ;;
        --static-only)
            static_only=1
            shift
            ;;
        --run-id)
            requested_run_id=${2:?--run-id requires a value}
            shift 2
            ;;
        --environment-note)
            environment_note=${2:?--environment-note requires a value}
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case ${pg_major} in
    17|18) ;;
    *) printf 'unsupported PostgreSQL major: %s\n' "${pg_major}" >&2; exit 2 ;;
esac
case ${profile} in
    acceptance|smoke) ;;
    *) printf 'profile must be acceptance or smoke: %s\n' "${profile}" >&2; exit 2 ;;
esac
case ${skip_build}:${static_only} in
    [01]:[01]) ;;
    *) printf 'PGS3_SKIP_BUILD and static-only must be boolean\n' >&2; exit 2 ;;
esac
if [[ ! ${minio_image} =~ ^.+@sha256:[0-9a-f]{64}$ ]]; then
    printf 'PGS3_BENCH_MINIO_IMAGE must be immutable name@sha256:<64 hex>: %s\n' \
        "${minio_image}" >&2
    exit 2
fi
for value_name in smoke_samples smoke_warmups smoke_concurrency; do
    value=${!value_name}
    if [[ ! ${value} =~ ^[0-9]+$ ]]; then
        printf '%s must be a nonnegative integer: %s\n' "${value_name}" "${value}" >&2
        exit 2
    fi
done
if ((smoke_samples < 1 || smoke_concurrency < 1)); then
    printf 'smoke samples and concurrency must be at least one\n' >&2
    exit 2
fi

# Re-evaluate the default after --pg parsing while preserving an explicit image.
if [[ -z ${PGS3_BENCH_PGS3_IMAGE:-} ]]; then
    pgs3_image="pgs3-test:pg${pg_major}"
fi

BENCH_PROFILE=${profile}
BENCH_PG_MAJOR=${pg_major}
BENCH_PGS3_IMAGE=${pgs3_image}
BENCH_MINIO_IMAGE=${minio_image}
BENCH_CLIENT_IMAGE=${client_image}
BENCH_SMOKE_SIZES=${smoke_sizes}
BENCH_SMOKE_SAMPLES=${smoke_samples}
BENCH_SMOKE_WARMUPS=${smoke_warmups}
BENCH_SMOKE_CONCURRENCY=${smoke_concurrency}
BENCH_ENVIRONMENT_NOTE=${environment_note}
if [[ ${profile} == acceptance ]]; then
    BENCH_WORKERS=16
    BENCH_SHARED_BUFFERS=1GB
else
    BENCH_WORKERS=2
    BENCH_SHARED_BUFFERS=256MB
fi

benchmark_suite="http-benchmark-${profile}"
if ((static_only)); then
    benchmark_suite=http-benchmark-static
fi
evidence_init "${repo_dir}" "${benchmark_suite}" "${pg_major}" "${requested_run_id}"
trap bench_cleanup EXIT INT TERM

benchmark_shell_sources=("${benchmark_dir}/run.sh" "${benchmark_dir}/harness_lib.sh")
benchmark_python_sources=(
    "${benchmark_dir}/benchmark.py"
    "${benchmark_dir}/environment.py"
    "${benchmark_dir}/test_benchmark.py"
    "${benchmark_dir}/test_static.py"
)

evidence_run benchmark-bash-syntax bash -n "${benchmark_shell_sources[@]}"
evidence_run benchmark-python-compile env \
    "PYTHONPYCACHEPREFIX=${PGS3_EVIDENCE_TMP}/pycache" \
    python3 -m py_compile "${benchmark_python_sources[@]}"
evidence_run benchmark-offline-tests env PYTHONDONTWRITEBYTECODE=1 \
    python3 -m unittest discover --start-directory "${benchmark_dir}" \
        --pattern 'test_*.py'
evidence_run benchmark-acceptance-description env PYTHONDONTWRITEBYTECODE=1 \
    python3 "${benchmark_dir}/benchmark.py" describe --profile acceptance
evidence_run benchmark-smoke-description env PYTHONDONTWRITEBYTECODE=1 \
    python3 "${benchmark_dir}/benchmark.py" describe --profile smoke \
        --smoke-sizes "${smoke_sizes}" \
        --smoke-samples "${smoke_samples}" \
        --smoke-warmups "${smoke_warmups}" \
        --smoke-concurrency "${smoke_concurrency}"
if command -v shellcheck >/dev/null 2>&1; then
    evidence_run benchmark-shellcheck shellcheck "${benchmark_shell_sources[@]}"
else
    evidence_run benchmark-shellcheck-unavailable bash -c \
        'printf "shellcheck unavailable; bash -n passed and absence is recorded.\n"'
fi

if ((static_only)); then
    BENCH_RESULT=PASS
    exit 0
fi

bench_require_command docker
bench_require_command python3
bench_require_command sha256sum
evidence_run benchmark-docker-version docker version
if ((skip_build)); then
    evidence_run benchmark-pgs3-image-inspect docker image inspect "${BENCH_PGS3_IMAGE}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
else
    evidence_run benchmark-pgs3-image-build "${repo_dir}/scripts/build-images.sh" "${pg_major}"
fi
evidence_run benchmark-minio-image-inspect docker image inspect "${BENCH_MINIO_IMAGE}" \
    --format 'digests={{json .RepoDigests}} id={{.Id}} created={{.Created}}'
evidence_run benchmark-client-image-inspect docker image inspect "${BENCH_CLIENT_IMAGE}" \
    --format 'digests={{json .RepoDigests}} id={{.Id}} created={{.Created}}'

bench_init_runtime
bench_start_pgs3
bench_start_minio
evidence_run benchmark-postgres-ready bench_wait_postgres
evidence_run benchmark-extension-bootstrap bench_install_pgs3
evidence_run benchmark-worker-pool-ready bench_wait_workers
evidence_run benchmark-pgs3-http-ready bench_wait_endpoint pgs3-benchmark 9000
evidence_run benchmark-minio-http-ready bench_wait_endpoint minio-benchmark 9000
evidence_run benchmark-minio-health-ready bench_wait_minio_health
evidence_run benchmark-environment-capture bench_capture_environment
evidence_run benchmark-execute bench_execute
evidence_run benchmark-metrics-flushed bench_wait_pgs3_metrics

BENCH_RESULT=PASS
