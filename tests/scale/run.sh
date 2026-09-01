#!/usr/bin/env bash
# shellcheck shell=bash
set -Eeuo pipefail

scale_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${scale_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local evidence helper
source "${repo_dir}/scripts/lib/evidence.sh"

pg_major=${PG_MAJOR:-17}
skip_build=${PGS3_SKIP_BUILD:-0}
static_only=0
requested_run_id=''

SCALE_FORK_OBJECTS=${PGS3_SCALE_FORK_OBJECTS:-100000}
SCALE_FORK_BLOBS=${PGS3_SCALE_FORK_BLOBS:-${SCALE_FORK_OBJECTS}}
SCALE_LIST_KEYS=${PGS3_SCALE_LIST_KEYS:-1000000}
SCALE_CHILD_PREFIXES=${PGS3_SCALE_CHILD_PREFIXES:-1000}
SCALE_PAGE_SIZE=${PGS3_SCALE_PAGE_SIZE:-1000}
SCALE_SHARED_BUFFERS=${PGS3_SCALE_SHARED_BUFFERS:-1GB}

SCALE_RESULT=RUNNING
SCALE_CLEANUP_FAILED=0
SCALE_CONTAINER=''
SCALE_RUN_TAG=''
SCALE_IMAGE=''
SCALE_GATE_FAILURES=0

usage() {
    cat <<'USAGE'
usage: tests/scale/run.sh [--pg 17|18] [--skip-build] [--static-only]
                          [--run-id ID]

One disposable PostgreSQL container loads and measures acceptance 7, 15, and
16.  Default acceptance data is 100,000 fork objects (100,000 distinct blobs),
1,000,000 latest LIST keys, 1,000 child prefixes, and 1,000 rows per measured
page.  Timing gates are fixed at fork <1000 ms, LIST <5 ms, and delimiter LIST
<10 ms and cannot be overridden.

For a non-acceptance developer smoke run, reduce all related dimensions while
keeping LIST_KEYS divisible by CHILD_PREFIXES, for example:

  PGS3_SCALE_FORK_OBJECTS=2000 PGS3_SCALE_FORK_BLOBS=2000 \
  PGS3_SCALE_LIST_KEYS=10000 PGS3_SCALE_CHILD_PREFIXES=100 \
  PGS3_SCALE_PAGE_SIZE=100 PGS3_SCALE_SHARED_BUFFERS=256MB \
  tests/scale/run.sh --pg 17 --skip-build

Every invocation creates artifacts/acceptance/<run>/manifest.json with the
workspace digest.  Runtime failures and missed thresholds remain FAIL evidence.
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
    *) printf 'skip-build and static-only must be boolean\n' >&2; exit 2 ;;
esac

scale_validate_positive_integer() {
    local name=$1 value=$2
    if [[ ! ${value} =~ ^[1-9][0-9]*$ ]]; then
        printf '%s must be a positive base-10 integer: %s\n' "${name}" "${value}" >&2
        return 2
    fi
}

scale_validate_config() {
    scale_validate_positive_integer PGS3_SCALE_FORK_OBJECTS "${SCALE_FORK_OBJECTS}"
    scale_validate_positive_integer PGS3_SCALE_FORK_BLOBS "${SCALE_FORK_BLOBS}"
    scale_validate_positive_integer PGS3_SCALE_LIST_KEYS "${SCALE_LIST_KEYS}"
    scale_validate_positive_integer PGS3_SCALE_CHILD_PREFIXES "${SCALE_CHILD_PREFIXES}"
    scale_validate_positive_integer PGS3_SCALE_PAGE_SIZE "${SCALE_PAGE_SIZE}"
    if ((SCALE_FORK_OBJECTS < 2)); then
        printf 'PGS3_SCALE_FORK_OBJECTS must be at least 2\n' >&2
        return 2
    fi
    if ((SCALE_FORK_BLOBS > SCALE_FORK_OBJECTS)); then
        printf 'PGS3_SCALE_FORK_BLOBS cannot exceed PGS3_SCALE_FORK_OBJECTS\n' >&2
        return 2
    fi
    if ((SCALE_LIST_KEYS % SCALE_CHILD_PREFIXES != 0)); then
        printf 'PGS3_SCALE_LIST_KEYS must be divisible by PGS3_SCALE_CHILD_PREFIXES\n' >&2
        return 2
    fi
    if ((SCALE_PAGE_SIZE > 1000)); then
        printf 'PGS3_SCALE_PAGE_SIZE cannot exceed the SQL API maximum of 1000\n' >&2
        return 2
    fi
    if ((SCALE_PAGE_SIZE > SCALE_CHILD_PREFIXES)); then
        printf 'PGS3_SCALE_PAGE_SIZE cannot exceed PGS3_SCALE_CHILD_PREFIXES\n' >&2
        return 2
    fi
    if ((SCALE_PAGE_SIZE > SCALE_LIST_KEYS / SCALE_CHILD_PREFIXES)); then
        printf 'each child prefix must contain at least PGS3_SCALE_PAGE_SIZE keys\n' >&2
        return 2
    fi
    if [[ ! ${SCALE_SHARED_BUFFERS} =~ ^[1-9][0-9]*(MB|GB)$ ]]; then
        printf 'PGS3_SCALE_SHARED_BUFFERS must use an integer MB or GB suffix\n' >&2
        return 2
    fi
}

scale_print_config() {
    local profile=scaled-development
    if ((SCALE_FORK_OBJECTS == 100000 \
        && SCALE_FORK_BLOBS == 100000 \
        && SCALE_LIST_KEYS == 1000000 \
        && SCALE_CHILD_PREFIXES == 1000 \
        && SCALE_PAGE_SIZE == 1000)); then
        profile=acceptance
    fi
    printf '%s\n' \
        "profile=${profile}" \
        "pg_major=${pg_major}" \
        "fork_objects=${SCALE_FORK_OBJECTS}" \
        "fork_distinct_blobs=${SCALE_FORK_BLOBS}" \
        "list_latest_keys=${SCALE_LIST_KEYS}" \
        "list_child_prefixes=${SCALE_CHILD_PREFIXES}" \
        "measured_page_size=${SCALE_PAGE_SIZE}" \
        "shared_buffers=${SCALE_SHARED_BUFFERS}" \
        'fork_gate_ms=<1000' \
        'list_gate_ms=<5' \
        'delimiter_gate_ms=<10' \
        'fsync=on full_page_writes=on synchronous_commit=on'
}

scale_required_command() {
    local name=$1
    if ! command -v "${name}" >/dev/null 2>&1; then
        printf 'required command is unavailable: %s\n' "${name}" >&2
        return 127
    fi
}

scale_safe_remove_container() {
    local label
    if [[ -z ${SCALE_CONTAINER} ]]; then
        return 0
    fi
    if ! docker container inspect "${SCALE_CONTAINER}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker container inspect "${SCALE_CONTAINER}" \
        --format '{{ index .Config.Labels "pgs3.scale.run" }}')
    if [[ -z ${SCALE_RUN_TAG} || ${label} != "${SCALE_RUN_TAG}" ]]; then
        printf 'refusing to remove container with unexpected label: %s label=%s\n' \
            "${SCALE_CONTAINER}" "${label}" >&2
        return 1
    fi
    docker rm --force --volumes "${SCALE_CONTAINER}"
    SCALE_CONTAINER=''
}

scale_cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    set +e

    if ! scale_safe_remove_container; then
        SCALE_CLEANUP_FAILED=1
        original_status=1
    fi

    if [[ ${SCALE_RESULT} == RUNNING ]]; then
        SCALE_RESULT=FAIL
        if ((original_status == 0)); then
            original_status=1
        fi
    fi
    if ((original_status != 0)) && [[ ${SCALE_RESULT} == PASS ]]; then
        SCALE_RESULT=FAIL
    fi
    if ((SCALE_CLEANUP_FAILED)); then
        SCALE_RESULT=FAIL
        original_status=1
    fi
    if [[ -n ${PGS3_RUN_DIR:-} && -f ${PGS3_RUN_DIR}/manifest.json ]]; then
        evidence_finalize "${SCALE_RESULT}" || original_status=1
        printf 'scale result: %s\nmanifest: %s/manifest.json\n' \
            "${SCALE_RESULT}" "${PGS3_RUN_DIR}"
    fi
    evidence_cleanup
    exit "${original_status}"
}

trap scale_cleanup EXIT INT TERM

evidence_init "${repo_dir}" scale "${pg_major}" "${requested_run_id}"
evidence_run scale-config-validation scale_validate_config
evidence_run scale-config scale_print_config
evidence_run scale-bash-syntax bash -n "${scale_dir}/run.sh"
evidence_run scale-python-compile env \
    "PYTHONPYCACHEPREFIX=${PGS3_EVIDENCE_TMP}/pycache" \
    python3 -m py_compile \
        "${scale_dir}/plan_check.py" "${scale_dir}/test_scale.py"
evidence_run scale-offline-tests env PYTHONDONTWRITEBYTECODE=1 \
    python3 -m unittest discover --start-directory "${scale_dir}" \
        --pattern 'test_*.py'
if command -v shellcheck >/dev/null 2>&1; then
    evidence_run scale-shellcheck shellcheck "${scale_dir}/run.sh"
else
    evidence_run scale-shellcheck-unavailable bash -c \
        'printf "shellcheck unavailable; bash -n passed and the absence is recorded.\\n"'
fi

if ((static_only)); then
    SCALE_RESULT=PASS
    exit 0
fi

evidence_run require-docker scale_required_command docker
evidence_run require-python scale_required_command python3

SCALE_IMAGE="${PGS3_IMAGE_PREFIX:-pgs3-test}:pg${pg_major}"
if ((skip_build)); then
    evidence_try server-image-inspect docker image inspect "${SCALE_IMAGE}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        evidence_blocked server-image \
            "${SCALE_IMAGE} is unavailable; build the current workspace before scale testing."
        SCALE_RESULT=BLOCKED
        exit 125
    fi
else
    evidence_run server-image-build "${repo_dir}/scripts/build-images.sh" "${pg_major}"
fi

SCALE_RUN_TAG=$(python3 -c \
    'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:12])' \
    "${PGS3_RUN_DIR}")
SCALE_CONTAINER="pgs3-scale-pg${pg_major}-${SCALE_RUN_TAG}"
if docker container inspect "${SCALE_CONTAINER}" >/dev/null 2>&1; then
    printf 'refusing to reuse pre-existing container: %s\n' "${SCALE_CONTAINER}" >&2
    exit 1
fi

scale_start_container() {
    docker run --detach \
        --name "${SCALE_CONTAINER}" \
        --label "pgs3.scale.run=${SCALE_RUN_TAG}" \
        --env POSTGRES_HOST_AUTH_METHOD=trust \
        "${SCALE_IMAGE}" \
        postgres \
        -c shared_preload_libraries=pgs3 \
        -c pgs3.enabled=off \
        -c pgs3.inline_threshold=64kB \
        -c pgs3.chunk_size=1MB \
        -c "shared_buffers=${SCALE_SHARED_BUFFERS}" \
        -c max_wal_size=4GB \
        -c checkpoint_timeout=30min \
        -c track_io_timing=on \
        -c jit=off \
        -c autovacuum=off \
        -c fsync=on \
        -c full_page_writes=on \
        -c synchronous_commit=on
}

scale_wait_postgres() {
    local _
    for _ in $(seq 1 120); do
        if docker exec "${SCALE_CONTAINER}" pg_isready \
            --username postgres --dbname postgres >/dev/null 2>&1; then
            docker exec "${SCALE_CONTAINER}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --tuples-only --no-align \
                --command "SELECT version(), pg_postmaster_start_time()"
            return 0
        fi
        sleep 1
    done
    printf 'PostgreSQL did not become ready in %s\n' "${SCALE_CONTAINER}" >&2
    docker logs "${SCALE_CONTAINER}" >&2 || true
    return 1
}

evidence_run container-start scale_start_container
evidence_run postgres-ready scale_wait_postgres
evidence_run extension-bootstrap docker exec "${SCALE_CONTAINER}" psql \
    --username postgres --dbname postgres --no-psqlrc --set ON_ERROR_STOP=1 \
    --command 'CREATE EXTENSION pgs3'

scale_psql_file() {
    local file=$1
    docker exec --interactive "${SCALE_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --set ON_ERROR_STOP=1 \
        --set "fork_objects=${SCALE_FORK_OBJECTS}" \
        --set "fork_blobs=${SCALE_FORK_BLOBS}" \
        --set "list_keys=${SCALE_LIST_KEYS}" \
        --set "child_prefixes=${SCALE_CHILD_PREFIXES}" \
        --set "page_size=${SCALE_PAGE_SIZE}" \
        <"${file}"
}

evidence_run fixture-load scale_psql_file "${scale_dir}/load.sql"

scale_scalar() {
    local sql=$1
    docker exec "${SCALE_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --set ON_ERROR_STOP=1 --tuples-only --no-align \
        --command "${sql}" | tr -d '[:space:]'
}

scale_assert_scalar() {
    local sql=$1 expected=$2 description=$3 actual
    actual=$(scale_scalar "${sql}")
    printf '%s: expected=%s actual=%s\n' "${description}" "${expected}" "${actual}"
    [[ ${actual} == "${expected}" ]]
}

scale_validate_fixture() {
    scale_assert_scalar \
        "SELECT count(*) FROM pgs3.object o JOIN pgs3.bucket b USING (bucket_id) WHERE b.name='scale-fork-source' AND o.is_latest AND NOT o.delete_marker" \
        "${SCALE_FORK_OBJECTS}" 'fork source latest objects'
    scale_assert_scalar \
        "SELECT count(DISTINCT o.blob_id) FROM pgs3.object o JOIN pgs3.bucket b USING (bucket_id) WHERE b.name='scale-fork-source'" \
        "${SCALE_FORK_BLOBS}" 'fork source distinct canonical blobs'
    scale_assert_scalar \
        "SELECT count(*) FROM (SELECT o.blob_id FROM pgs3.object o JOIN pgs3.bucket bucket USING (bucket_id) JOIN pgs3.blob blob ON blob.sha256=o.blob_id WHERE bucket.name='scale-fork-source' GROUP BY o.blob_id, blob.refcount HAVING blob.refcount <> count(*)) mismatch" \
        0 'fork source refcounts'
    scale_assert_scalar \
        "SELECT count(*) FROM pgs3.object o JOIN pgs3.bucket b USING (bucket_id) WHERE b.name='scale-list' AND o.is_latest AND NOT o.delete_marker" \
        "${SCALE_LIST_KEYS}" 'LIST latest keys'
    scale_assert_scalar \
        "SELECT count(DISTINCT split_part(substr(o.key, 6), '/', 1)) FROM pgs3.object o JOIN pgs3.bucket b USING (bucket_id) WHERE b.name='scale-list'" \
        "${SCALE_CHILD_PREFIXES}" 'LIST child prefixes'
    scale_assert_scalar \
        "SELECT bool_and(blob.refcount=${SCALE_LIST_KEYS}) FROM pgs3.object o JOIN pgs3.bucket bucket USING (bucket_id) JOIN pgs3.blob blob ON blob.sha256=o.blob_id WHERE bucket.name='scale-list'" \
        t 'LIST shared canonical blob refcount'
}

evidence_run fixture-integrity scale_validate_fixture

scale_environment() {
    uname -a
    docker version --format 'docker_server={{.Server.Version}} os={{.Server.Os}} arch={{.Server.Arch}}'
    docker image inspect "${SCALE_IMAGE}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
    docker exec "${SCALE_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc --tuples-only --no-align \
        --command "SELECT name || '=' || setting || coalesce(unit,'') FROM pg_settings WHERE name IN ('shared_buffers','fsync','full_page_writes','synchronous_commit','track_io_timing','jit','autovacuum') ORDER BY name"
    docker exec "${SCALE_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc --tuples-only --no-align \
        --command "SELECT 'database_bytes=' || pg_database_size(current_database()) UNION ALL SELECT 'object_heap_bytes=' || pg_relation_size('pgs3.object') UNION ALL SELECT 'object_indexes_bytes=' || pg_indexes_size('pgs3.object') UNION ALL SELECT 'blob_heap_bytes=' || pg_relation_size('pgs3.blob')"
}

evidence_run environment-and-dataset scale_environment
mkdir -p -- "${PGS3_RUN_DIR}/plans"

scale_warm_fork_source() {
    # Read every source metadata/blob datum needed by fork_bucket after the
    # million-key fixture validation, so the measured fork represents the
    # acceptance contract's hot-data condition rather than cache eviction by
    # the unrelated LIST bucket.
    scale_assert_scalar \
        "SELECT count(*) FROM pgs3.object o JOIN pgs3.bucket bucket USING (bucket_id) JOIN pgs3.blob blob ON blob.sha256=o.blob_id WHERE bucket.name='scale-fork-source' AND o.is_latest AND o.version_id + o.size + octet_length(o.key) + octet_length(coalesce(o.etag,'')) + octet_length(coalesce(o.sha256,''::bytea)) + octet_length(coalesce(o.content_type,'')) + octet_length(o.meta::text) + octet_length(coalesce(o.blob_id,''::bytea)) + octet_length(blob.inline) >= 0" \
        "${SCALE_FORK_OBJECTS}" 'warm fork source metadata and canonical blobs'
}

evidence_run fork-source-warmup scale_warm_fork_source

scale_capture_plan() {
    local sql_file=$1 plan_file=$2
    docker exec --interactive "${SCALE_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --quiet --tuples-only --no-align --set ON_ERROR_STOP=1 \
        --set "fork_objects=${SCALE_FORK_OBJECTS}" \
        --set "fork_blobs=${SCALE_FORK_BLOBS}" \
        --set "page_size=${SCALE_PAGE_SIZE}" \
        <"${sql_file}" >"${plan_file}"
    python3 -m json.tool "${plan_file}"
}

scale_gate_plan() {
    local kind=$1 plan_file=$2 expected_rows=$3 summary_file=$4
    python3 "${scale_dir}/plan_check.py" \
        --kind "${kind}" --plan "${plan_file}" \
        --expected-rows "${expected_rows}" | tee "${summary_file}"
}

fork_plan="${PGS3_RUN_DIR}/plans/fork.json"
evidence_try fork-explain-analyze scale_capture_plan \
    "${scale_dir}/plan_fork.sql" "${fork_plan}"
if ((PGS3_EVIDENCE_LAST_RC == 0)); then
    evidence_try fork-under-1s scale_gate_plan fork "${fork_plan}" 1 \
        "${PGS3_RUN_DIR}/plans/fork-summary.json"
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
    fi
else
    SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
fi

scale_validate_fork_before_mutation() {
    scale_assert_scalar \
        "SELECT count(*) FROM pgs3.object o JOIN pgs3.bucket b USING (bucket_id) WHERE b.name='scale-fork-destination' AND o.is_latest" \
        "${SCALE_FORK_OBJECTS}" 'fork destination latest rows'
    scale_assert_scalar \
        "SELECT count(DISTINCT o.blob_id) FROM pgs3.object o JOIN pgs3.bucket b USING (bucket_id) WHERE b.name='scale-fork-destination'" \
        "${SCALE_FORK_BLOBS}" 'fork destination distinct canonical blobs'
    scale_assert_scalar \
        "SELECT count(*) FROM (SELECT blob.sha256 FROM pgs3.blob blob LEFT JOIN pgs3.object o ON o.blob_id=blob.sha256 GROUP BY blob.sha256, blob.refcount HAVING blob.refcount <> count(o.*)) mismatch" \
        0 'post-fork global refcount reconciliation'
}

evidence_try fork-refcount-after-copy scale_validate_fork_before_mutation
if ((PGS3_EVIDENCE_LAST_RC != 0)); then
    SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
fi
evidence_try fork-independent-writes scale_psql_file \
    "${scale_dir}/verify_independence.sql"
if ((PGS3_EVIDENCE_LAST_RC != 0)); then
    SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
fi

scale_warm_lists() {
    scale_assert_scalar \
        "SELECT count(*) FROM pgs3.list_objects_v2('scale-list','tree/000001/',NULL,NULL,NULL,${SCALE_PAGE_SIZE})" \
        "${SCALE_PAGE_SIZE}" 'warm ordinary LIST rows'
    scale_assert_scalar \
        "SELECT count(*) FROM pgs3.list_objects_v2('scale-list','tree/','/',NULL,NULL,${SCALE_PAGE_SIZE})" \
        "${SCALE_PAGE_SIZE}" 'warm delimiter LIST rows'
}

evidence_run list-warmup scale_warm_lists

list_plan="${PGS3_RUN_DIR}/plans/list.json"
evidence_try list-explain-analyze scale_capture_plan \
    "${scale_dir}/plan_list.sql" "${list_plan}"
if ((PGS3_EVIDENCE_LAST_RC == 0)); then
    evidence_try list-under-5ms scale_gate_plan list "${list_plan}" \
        "${SCALE_PAGE_SIZE}" "${PGS3_RUN_DIR}/plans/list-summary.json"
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
    fi
else
    SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
fi

delimiter_plan="${PGS3_RUN_DIR}/plans/delimiter.json"
evidence_try delimiter-explain-analyze scale_capture_plan \
    "${scale_dir}/plan_delimiter.sql" "${delimiter_plan}"
if ((PGS3_EVIDENCE_LAST_RC == 0)); then
    evidence_try delimiter-under-10ms scale_gate_plan delimiter \
        "${delimiter_plan}" "${SCALE_PAGE_SIZE}" \
        "${PGS3_RUN_DIR}/plans/delimiter-summary.json"
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
    fi
else
    SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
fi

evidence_try list-result-shapes scale_psql_file "${scale_dir}/verify_list.sql"
if ((PGS3_EVIDENCE_LAST_RC != 0)); then
    SCALE_GATE_FAILURES=$((SCALE_GATE_FAILURES + 1))
fi

if ((SCALE_GATE_FAILURES != 0)); then
    printf '%s scale gate(s) failed; all observed evidence is retained.\n' \
        "${SCALE_GATE_FAILURES}" >&2
    SCALE_RESULT=FAIL
    exit 1
fi

SCALE_RESULT=PASS
