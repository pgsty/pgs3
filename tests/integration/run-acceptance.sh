#!/usr/bin/env bash
set -Eeuo pipefail

integration_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${integration_dir}/../.." && pwd)
# shellcheck disable=SC1091 # resolved from this file, not the caller's cwd
source "${integration_dir}/harness_lib.sh"

mode=http-smoke
pg_major=${PG_MAJOR:-17}
skip_build=${PGS3_SKIP_BUILD:-0}
mandatory=${PGS3_MANDATORY:-1}
requested_run_id=''

usage() {
    cat <<'USAGE'
usage: run-acceptance.sh [--mode http-smoke|clients] [--pg 17|18]
                         [--skip-build] [--mandatory|--allow-blocked]
                         [--run-id ID]

Every invocation creates artifacts/acceptance/<UTC-run-id>/manifest.json.
Mandatory mode is the default and returns nonzero when a required client is
blocked.  --allow-blocked still records BLOCKED (never PASS) but returns zero
when no runnable case failed.
USAGE
}

while (($#)); do
    case $1 in
        --mode)
            mode=${2:?--mode requires a value}
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
        --mandatory)
            mandatory=1
            shift
            ;;
        --allow-blocked)
            mandatory=0
            shift
            ;;
        --run-id)
            requested_run_id=${2:?--run-id requires a value}
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

case ${mode} in
    http-smoke|clients) ;;
    *) printf 'unsupported acceptance mode: %s\n' "${mode}" >&2; exit 2 ;;
esac
case ${pg_major} in
    17|18) ;;
    *) printf 'unsupported PostgreSQL major: %s\n' "${pg_major}" >&2; exit 2 ;;
esac
case ${skip_build}:${mandatory} in
    [01]:[01]) ;;
    *) printf 'PGS3_SKIP_BUILD and PGS3_MANDATORY must be 0 or 1\n' >&2; exit 2 ;;
esac

evidence_init "${repo_dir}" "${mode}" "${pg_major}" "${requested_run_id}"
trap harness_cleanup EXIT INT TERM

mapfile -t shell_sources < <(find "${repo_dir}/scripts" "${integration_dir}" \
    -type f -name '*.sh' -print | sort)
mapfile -t python_sources < <(find "${repo_dir}/scripts" "${integration_dir}" \
    -type f -name '*.py' -print | sort)
evidence_run docker-version docker version
evidence_run python-version python3 --version
evidence_run bash-syntax bash -n "${shell_sources[@]}"
evidence_run python-compile python3 -m py_compile "${python_sources[@]}"
if command -v shellcheck >/dev/null 2>&1; then
    evidence_run shellcheck shellcheck "${shell_sources[@]}"
else
    evidence_run shellcheck-availability bash -c \
        'printf "shellcheck unavailable on host; bash -n completed and absence is recorded.\\n"'
fi
evidence_run python-offline-tests python3 -m unittest discover \
    --start-directory "${integration_dir}" --pattern 'test_*.py'
evidence_run sigv4-offline-tests python3 "${integration_dir}/sigv4_probe.py" --self-test

harness_require_command docker
harness_require_command python3
harness_start_server "${pg_major}" "${skip_build}"
harness_probe initial
harness_dynamic_lifecycle
evidence_run runtime-metrics harness_wait_metrics

if [[ ${mode} == http-smoke ]]; then
    export harness_result=PASS
    exit 0
fi

harness_build_client_image
harness_client_environment
suffix=$(printf '%s' "${PGS3_RUN_DIR}" | sha256sum | cut -c1-10)
matrix_failed=0
matrix_blocked=0

for case_name in versions aws-s3api aws-s3 aws-multipart rclone boto3 duckdb; do
    bucket="client-${case_name//[^a-z0-9]/-}-${suffix}"
    evidence_try "client-${case_name}" harness_run_client_case \
        "${case_name}" "${bucket}"
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        matrix_failed=1
    fi
done

evidence_try client-s3fs-preflight harness_fuse_preflight
if ((PGS3_EVIDENCE_LAST_RC == 0)); then
    : "${harness_fuse_mode:=}"
    case ${harness_fuse_mode} in
        device)
            fuse_args=(
                --device /dev/fuse
                --cap-add SYS_ADMIN
                --security-opt apparmor=unconfined
            )
            ;;
        privileged)
            fuse_args=(--privileged --env PGS3_CREATE_FUSE_DEVICE=1)
            ;;
        *)
            printf 'FUSE preflight returned success without a mode\n' >&2
            exit 1
            ;;
    esac
    evidence_try client-s3fs harness_run_client_case \
        s3fs "client-s3fs-${suffix}" "${fuse_args[@]}"
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        matrix_failed=1
    fi
else
    matrix_blocked=1
    evidence_blocked client-s3fs \
        'FUSE preflight failed: a usable /dev/fuse plus Docker mount privileges are required for the mandatory s3fs vim/grep/find test.'
fi

if ((matrix_failed)); then
    export harness_result=FAIL
    exit 1
fi
if ((matrix_blocked)); then
    export harness_result=BLOCKED
    if ((mandatory)); then
        exit 125
    fi
    exit 0
fi

export harness_result=PASS
