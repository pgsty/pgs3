#!/usr/bin/env bash
# shellcheck disable=SC2034 # state is consumed by the sourced EXIT trap/scenarios
set -Eeuo pipefail

reliability_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${reliability_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local harness
source "${reliability_dir}/harness_lib.sh"
# shellcheck disable=SC1091 # repository-local scenarios
source "${reliability_dir}/scenarios.sh"

scenario=all
pg_major=${PG_MAJOR:-17}
skip_build=${PGS3_SKIP_BUILD:-0}
static_only=0
requested_run_id=''

usage() {
    cat <<'USAGE'
usage: run.sh [--scenario crash|fast-stop|reload|standby|all] [--pg 17|18]
              [--skip-build] [--static-only] [--run-id ID]

Every invocation writes a redacted manifest under artifacts/acceptance/.  A
runtime scenario returns nonzero on a failed assertion or unavailable image;
only --static-only can PASS without launching PostgreSQL.  The standby gate is
defined for PostgreSQL 17, and `all` therefore requires --pg 17.
USAGE
}

while (($#)); do
    case $1 in
        --scenario)
            scenario=${2:?--scenario requires a value}
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

case ${scenario} in
    crash|fast-stop|reload|standby|all) ;;
    *) printf 'unsupported reliability scenario: %s\n' "${scenario}" >&2; exit 2 ;;
esac
case ${pg_major} in
    17|18) ;;
    *) printf 'unsupported PostgreSQL major: %s\n' "${pg_major}" >&2; exit 2 ;;
esac
case ${skip_build}:${static_only} in
    [01]:[01]) ;;
    *) printf 'PGS3_SKIP_BUILD and static mode must be boolean\n' >&2; exit 2 ;;
esac
if ((!static_only)) \
    && [[ ${scenario} == standby || ${scenario} == all ]] \
    && [[ ${pg_major} != 17 ]]; then
    printf '%s is a PostgreSQL 17 reliability gate\n' "${scenario}" >&2
    exit 2
fi

# Shared with scenarios.sh after it is sourced above.
REL_PG_MAJOR=${pg_major}
REL_IMAGE="${PGS3_IMAGE_PREFIX:-pgs3-test}:pg${pg_major}"
suite="reliability-${scenario}"
if ((static_only)); then
    suite=reliability-static
fi
evidence_init "${repo_dir}" "${suite}" "${pg_major}" "${requested_run_id}"
trap rel_cleanup EXIT INT TERM

mapfile -t reliability_shell < <(
    find "${reliability_dir}" "${repo_dir}/scripts" -maxdepth 1 \
        -type f \( -name 'reliability-*.sh' -o -path "${reliability_dir}/*.sh" \) \
        -print | sort
)
mapfile -t reliability_python < <(
    find "${reliability_dir}" -maxdepth 1 -type f -name '*.py' -print | sort
)
evidence_run reliability-bash-syntax bash -n "${reliability_shell[@]}"
evidence_run reliability-python-compile env \
    "PYTHONPYCACHEPREFIX=${PGS3_EVIDENCE_TMP}/pycache" \
    python3 -m py_compile "${reliability_python[@]}"
evidence_run reliability-offline-tests env PYTHONDONTWRITEBYTECODE=1 \
    python3 -m unittest discover --start-directory "${reliability_dir}" \
        --pattern 'test_*.py'
if command -v shellcheck >/dev/null 2>&1; then
    evidence_run reliability-shellcheck shellcheck "${reliability_shell[@]}"
else
    evidence_run reliability-shellcheck-unavailable bash -c \
        'printf "shellcheck unavailable; bash -n passed and the absence is recorded.\\n"'
fi

if ((static_only)); then
    REL_RESULT=PASS
    exit 0
fi

rel_require_command docker
rel_require_command python3
rel_require_command timeout
rel_require_command sha256sum
if ((skip_build)); then
    evidence_try server-image-inspect docker image inspect "${REL_IMAGE}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        evidence_blocked server-image \
            "${REL_IMAGE} is unavailable; build the current workspace before runtime reliability testing."
        REL_RESULT=BLOCKED
        exit 125
    fi
else
    evidence_run server-image-build "${repo_dir}/scripts/build-images.sh" "${pg_major}"
fi
rel_init_runtime

case ${scenario} in
    crash) scenario_crash ;;
    fast-stop) scenario_fast_stop ;;
    reload) scenario_reload ;;
    standby) scenario_standby ;;
    all)
        scenario_crash
        scenario_fast_stop
        scenario_reload
        scenario_standby
        ;;
esac

# Read by the EXIT trap installed in harness_lib.sh.
REL_RESULT=PASS
