#!/usr/bin/env bash
# shellcheck disable=SC2034 # state is consumed by the sourced harness and EXIT trap
set -Eeuo pipefail

robust_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${robust_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local harness
source "${robust_dir}/harness_lib.sh"

pg_major=${PG_MAJOR:-17}
static_only=0
requested_run_id=''
robust_workers=${PGS3_ROBUST_WORKERS:-3}

usage() {
    cat <<'USAGE'
usage: run.sh [--pg 17|18] [--static-only] [--run-id ID]
              [--workers N]

The runtime gate creates exactly one disposable pgs3 container on a dedicated,
run-labeled Docker network.  Its only published socket is an ephemeral
127.0.0.1 port.  A fixed seven-case boundary corpus is grouped by request head,
message body/XML, and chunked framing.  After every group, a valid SigV4 GET
must succeed and the postmaster start time and HTTP worker pool must retain
their exact baseline identity.  There is no target option, discovery, or scan.

--static-only is offline: it runs syntax, unit, source-policy, and fixed-corpus
checks without requiring Docker or building an image.

Runtime also never pulls or builds an image.  It fails closed unless the local
pgs3-test:pgMAJOR image (or local PGS3_IMAGE_PREFIX equivalent) already exists.
USAGE
}

while (($#)); do
    case $1 in
        --pg)
            pg_major=${2:?--pg requires a value}
            shift 2
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
            robust_workers=${2:?--workers requires a value}
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
[[ ${static_only} == 0 || ${static_only} == 1 ]]
if [[ ! ${robust_workers} =~ ^[0-9]+$ ]] \
    || ((robust_workers < 1 || robust_workers > 16)); then
    printf 'workers must be an integer in 1..16\n' >&2
    exit 2
fi

ROBUST_IMAGE="${PGS3_IMAGE_PREFIX:-pgs3-test}:pg${pg_major}"
ROBUST_WORKERS=${robust_workers}
ROBUST_BATCHES=(request-head message-body chunked-body)

suite=http-robustness
if ((static_only)); then
    suite=http-robustness-static
fi
evidence_init "${repo_dir}" "${suite}" "${pg_major}" "${requested_run_id}"
trap robust_cleanup EXIT INT TERM

robust_shell_sources=(
    "${robust_dir}/run.sh"
    "${robust_dir}/harness_lib.sh"
)
robust_python_sources=("${robust_dir}"/*.py)

evidence_run robustness-bash-syntax bash -n "${robust_shell_sources[@]}"
evidence_run robustness-python-compile env \
    "PYTHONPYCACHEPREFIX=${PGS3_EVIDENCE_TMP}/pycache" \
    python3 -m py_compile "${robust_python_sources[@]}"
evidence_run robustness-offline-tests env PYTHONDONTWRITEBYTECODE=1 \
    python3 -m unittest discover --start-directory "${robust_dir}" \
        --pattern 'test_*.py'
evidence_run robustness-corpus-description env PYTHONDONTWRITEBYTECODE=1 \
    python3 "${robust_dir}/http_boundary.py" describe
if command -v shellcheck >/dev/null 2>&1; then
    evidence_run robustness-shellcheck shellcheck "${robust_shell_sources[@]}"
else
    evidence_run robustness-shellcheck-unavailable bash -c \
        'printf "shellcheck unavailable; bash -n passed and absence is recorded.\\n"'
fi

if ((static_only)); then
    ROBUST_RESULT=PASS
    exit 0
fi

robust_require_command docker
robust_require_command python3
evidence_try robustness-server-image-inspect docker image inspect \
    "${ROBUST_IMAGE}" \
    --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
if ((PGS3_EVIDENCE_LAST_RC != 0)); then
    evidence_blocked robustness-server-image \
        "${ROBUST_IMAGE} is unavailable; build it separately before the local-only robustness gate."
    ROBUST_RESULT=BLOCKED
    exit 125
fi

robust_init_runtime
robust_start_server
evidence_run robustness-runtime-scope robust_assert_scope
evidence_run robustness-postgres-ready robust_wait_postgres
evidence_run robustness-extension-bootstrap robust_bootstrap_extension
evidence_run robustness-worker-pool-ready robust_wait_workers
evidence_run robustness-http-port-ready robust_wait_port
evidence_run robustness-sentinel-setup robust_setup_sentinel
evidence_run robustness-runtime-baseline robust_capture_baseline
evidence_run robustness-legal-before-corpus robust_probe_sentinel
evidence_run robustness-runtime-before-corpus robust_assert_runtime

for batch in "${ROBUST_BATCHES[@]}"; do
    evidence_run "robustness-runtime-before-${batch}" robust_assert_runtime
    evidence_run "robustness-batch-${batch}" robust_run_batch "${batch}"
    evidence_run "robustness-legal-after-${batch}" robust_probe_sentinel
    evidence_run "robustness-runtime-after-${batch}" robust_assert_runtime
done

evidence_run robustness-legal-after-corpus robust_probe_sentinel
evidence_run robustness-runtime-after-corpus robust_assert_runtime

ROBUST_RESULT=PASS
