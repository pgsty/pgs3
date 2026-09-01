#!/usr/bin/env bash
# shellcheck disable=SC2034 # state is consumed by sourced harness and EXIT trap
set -Eeuo pipefail

fuzz_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${fuzz_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local harness
source "${fuzz_dir}/harness_lib.sh"

pg_major=${PG_MAJOR:-17}
skip_build=${PGS3_SKIP_BUILD:-0}
static_only=0
requested_run_id=''
fuzz_workers=${PGS3_FUZZ_WORKERS:-3}
fuzz_seed=${PGS3_FUZZ_SEED:-pgs3-acceptance-9-v1}
fuzz_random_cases=${PGS3_FUZZ_RANDOM_CASES:-16}
fuzz_case_timeout=${PGS3_FUZZ_CASE_TIMEOUT:-3}

usage() {
    cat <<'USAGE'
usage: run.sh [--pg 17|18] [--skip-build] [--static-only] [--run-id ID]
              [--workers N] [--seed SEED] [--random-cases N]
              [--case-timeout SECONDS]

The runtime gate sends a bounded deterministic malformed-request corpus and
requires the PostgreSQL start time and exact HTTP worker PID set to remain
unchanged around every case.  Every case is followed by a valid signed GET.
Credentials exist only in environment variables and evidence is redacted.
USAGE
}

while (($#)); do
    case $1 in
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
        --workers)
            fuzz_workers=${2:?--workers requires a value}
            shift 2
            ;;
        --seed)
            fuzz_seed=${2:?--seed requires a value}
            shift 2
            ;;
        --random-cases)
            fuzz_random_cases=${2:?--random-cases requires a value}
            shift 2
            ;;
        --case-timeout)
            fuzz_case_timeout=${2:?--case-timeout requires a value}
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
case ${skip_build}:${static_only} in
    [01]:[01]) ;;
    *) printf 'PGS3_SKIP_BUILD and static mode must be boolean\n' >&2; exit 2 ;;
esac
if [[ ! ${fuzz_workers} =~ ^[0-9]+$ ]] \
    || ((fuzz_workers < 1 || fuzz_workers > 16)); then
    printf 'workers must be an integer in 1..16\n' >&2
    exit 2
fi
if [[ ! ${fuzz_random_cases} =~ ^[0-9]+$ ]] \
    || ((fuzz_random_cases < 1 || fuzz_random_cases > 64)); then
    printf 'random case count must be an integer in 1..64\n' >&2
    exit 2
fi

FUZZ_IMAGE="${PGS3_IMAGE_PREFIX:-pgs3-test}:pg${pg_major}"
FUZZ_WORKERS=${fuzz_workers}
FUZZ_SEED=${fuzz_seed}
FUZZ_RANDOM_CASES=${fuzz_random_cases}
FUZZ_CASE_TIMEOUT=${fuzz_case_timeout}

suite=fuzz-malformed
if ((static_only)); then
    suite=fuzz-static
fi
evidence_init "${repo_dir}" "${suite}" "${pg_major}" "${requested_run_id}"
trap fuzz_cleanup EXIT INT TERM

mapfile -t fuzz_shell_sources < <(
    find "${fuzz_dir}" -maxdepth 1 -type f -name '*.sh' -print | sort
)
mapfile -t fuzz_python_sources < <(
    find "${fuzz_dir}" -maxdepth 1 -type f -name '*.py' -print | sort
)
evidence_run fuzz-bash-syntax bash -n "${fuzz_shell_sources[@]}"
evidence_run fuzz-python-compile env \
    "PYTHONPYCACHEPREFIX=${PGS3_EVIDENCE_TMP}/pycache" \
    python3 -m py_compile "${fuzz_python_sources[@]}"
evidence_run fuzz-offline-tests env PYTHONDONTWRITEBYTECODE=1 \
    python3 -m unittest discover --start-directory "${fuzz_dir}" \
        --pattern 'test_*.py'
evidence_run fuzz-corpus-description env PYTHONDONTWRITEBYTECODE=1 \
    python3 "${fuzz_dir}/malformed_client.py" describe \
        --seed "${FUZZ_SEED}" \
        --random-cases "${FUZZ_RANDOM_CASES}" \
        --timeout "${FUZZ_CASE_TIMEOUT}"
if command -v shellcheck >/dev/null 2>&1; then
    evidence_run fuzz-shellcheck shellcheck "${fuzz_shell_sources[@]}"
else
    evidence_run fuzz-shellcheck-unavailable bash -c \
        'printf "shellcheck unavailable; bash -n passed and absence is recorded.\\n"'
fi

if ((static_only)); then
    FUZZ_RESULT=PASS
    exit 0
fi

fuzz_require_command docker
fuzz_require_command python3
fuzz_require_command sha256sum
if ((skip_build)); then
    evidence_try fuzz-server-image-inspect docker image inspect "${FUZZ_IMAGE}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        evidence_blocked fuzz-server-image \
            "${FUZZ_IMAGE} is unavailable; build the current workspace before runtime malformed-request testing."
        FUZZ_RESULT=BLOCKED
        exit 125
    fi
else
    evidence_run fuzz-server-image-build "${repo_dir}/scripts/build-images.sh" "${pg_major}"
fi

fuzz_init_runtime
fuzz_start_server
evidence_run fuzz-postgres-ready fuzz_wait_postgres
evidence_run fuzz-extension-bootstrap fuzz_bootstrap_extension
evidence_run fuzz-worker-pool-ready fuzz_wait_workers
evidence_run fuzz-http-port-ready fuzz_wait_port
evidence_run fuzz-case-materialize fuzz_materialize_cases
evidence_run fuzz-sentinel-setup fuzz_setup_sentinel
evidence_run fuzz-runtime-baseline fuzz_capture_baseline
evidence_run fuzz-runtime-before-corpus fuzz_assert_runtime
evidence_run fuzz-legal-before-corpus fuzz_probe_sentinel

mapfile -t fuzz_cases <"${FUZZ_CASE_FILE}"
expected_cases=$((8 + FUZZ_RANDOM_CASES))
printf 'materialized malformed corpus: expected=%s actual=%s\n' \
    "${expected_cases}" "${#fuzz_cases[@]}"
[[ ${#fuzz_cases[@]} -eq ${expected_cases} ]]

for case_name in "${fuzz_cases[@]}"; do
    evidence_run "fuzz-runtime-before-${case_name}" fuzz_assert_runtime
    evidence_run "fuzz-case-${case_name}" fuzz_run_case "${case_name}"
    evidence_run "fuzz-runtime-after-${case_name}" fuzz_assert_runtime
done

evidence_run fuzz-legal-after-corpus fuzz_probe_sentinel
evidence_run fuzz-sentinel-cleanup fuzz_cleanup_sentinel
evidence_run fuzz-runtime-after-corpus fuzz_assert_runtime

FUZZ_RESULT=PASS
