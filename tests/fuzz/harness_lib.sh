#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # state is shared with run.sh

fuzz_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${fuzz_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local evidence helper
source "${repo_dir}/scripts/lib/evidence.sh"

export PGS3_FUZZ_ACCESS_KEY=${PGS3_FUZZ_ACCESS_KEY:-PGS3FUZZACCESS0001}
if [[ -z ${PGS3_FUZZ_SECRET:-} ]]; then
    PGS3_FUZZ_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    export PGS3_FUZZ_SECRET
fi
export PGS3_REDACT_ENV_NAMES="${PGS3_REDACT_ENV_NAMES:+${PGS3_REDACT_ENV_NAMES},}PGS3_FUZZ_ACCESS_KEY,PGS3_FUZZ_SECRET"

FUZZ_RESULT=RUNNING
FUZZ_CLEANUP_FAILED=0
FUZZ_RUN_TAG=''
FUZZ_TMP_DIR=''
FUZZ_NETWORK=''
FUZZ_CONTAINER=''
FUZZ_IMAGE=''
FUZZ_HOST_PORT=''
FUZZ_WORKERS=''
FUZZ_SEED=''
FUZZ_RANDOM_CASES=''
FUZZ_CASE_TIMEOUT=''
FUZZ_BUCKET=''
FUZZ_SCRATCH_BUCKET=''
FUZZ_SENTINEL_KEY='sentinel/healthy.bin'
FUZZ_CASE_FILE=''
FUZZ_BASE_POSTMASTER_START=''
FUZZ_BASE_WORKER_PIDS=''
FUZZ_BASE_CONTAINER_PID=''

fuzz_require_command() {
    local command=$1
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'required command is unavailable: %s\n' "${command}" >&2
        return 127
    fi
}

fuzz_pick_port() {
    python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

fuzz_init_runtime() {
    FUZZ_RUN_TAG=$(printf '%s' "${PGS3_RUN_DIR}" | sha256sum | cut -c1-12)
    FUZZ_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pgs3-fuzz.XXXXXXXX")
    FUZZ_NETWORK="pgs3-fuzz-net-${FUZZ_RUN_TAG}"
    FUZZ_CONTAINER="pgs3-fuzz-${FUZZ_RUN_TAG}"
    FUZZ_CASE_FILE="${FUZZ_TMP_DIR}/cases.txt"
    FUZZ_HOST_PORT=$(fuzz_pick_port)
    FUZZ_BUCKET="fuzz-${FUZZ_RUN_TAG}"
    FUZZ_SCRATCH_BUCKET="fuzz-xml-${FUZZ_RUN_TAG}"
    evidence_run fuzz-network-create docker network create \
        --label "pgs3.fuzz.run=${FUZZ_RUN_TAG}" \
        "${FUZZ_NETWORK}"
}

fuzz_start_server() {
    evidence_run fuzz-server-start docker run --detach \
        --name "${FUZZ_CONTAINER}" \
        --label "pgs3.fuzz.run=${FUZZ_RUN_TAG}" \
        --network "${FUZZ_NETWORK}" \
        --publish "127.0.0.1:${FUZZ_HOST_PORT}:9000" \
        --env POSTGRES_HOST_AUTH_METHOD=trust \
        --shm-size 256m \
        "${FUZZ_IMAGE}" \
        postgres \
        -c shared_preload_libraries=pgs3 \
        -c max_worker_processes=32 \
        -c pgs3.enabled=off \
        -c pgs3.listen_addr=0.0.0.0 \
        -c pgs3.port=9000 \
        -c "pgs3.workers=${FUZZ_WORKERS}" \
        -c pgs3.statement_timeout_ms=3000 \
        -c log_min_messages=info \
        -c 'log_line_prefix=%m [%p] %q%u@%d '
}

fuzz_wait_postgres() {
    local last=''
    printf 'waiting for PostgreSQL in %s\n' "${FUZZ_CONTAINER}"
    for _ in $(seq 1 120); do
        if docker exec "${FUZZ_CONTAINER}" pg_isready \
            --username postgres --dbname postgres >/dev/null 2>&1; then
            docker exec "${FUZZ_CONTAINER}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --tuples-only --no-align --command \
                "SELECT current_setting('server_version'), pg_postmaster_start_time()"
            return 0
        fi
        last=$(docker container inspect "${FUZZ_CONTAINER}" \
            --format '{{.State.Status}}|{{.State.ExitCode}}|{{.State.Error}}' 2>/dev/null || true)
        sleep 1
    done
    printf 'PostgreSQL did not become ready in 120 seconds: %s\n' "${last}" >&2
    return 1
}

fuzz_bootstrap_extension() {
    docker exec --interactive \
        --env PGS3_FUZZ_ACCESS_KEY \
        --env PGS3_FUZZ_SECRET \
        "${FUZZ_CONTAINER}" \
        bash -Eeuo pipefail -c '
            psql --username postgres --dbname postgres --no-psqlrc \
                --set ON_ERROR_STOP=1 \
                --set access_key="$PGS3_FUZZ_ACCESS_KEY" \
                --set secret="$PGS3_FUZZ_SECRET"
        ' <<'SQL'
CREATE EXTENSION pgs3;
CREATE ROLE pgs3_fuzz_tenant
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;
SELECT pgs3.create_credential(
    :'access_key', :'secret', 'pgs3_fuzz_tenant'::name, true
);
SELECT pgs3.start();
SQL
}

fuzz_scalar() {
    local sql=$1
    docker exec "${FUZZ_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --tuples-only --no-align --set ON_ERROR_STOP=1 \
        --command "${sql}" | tr -d '[:space:]'
}

fuzz_wait_workers() {
    local ready=''
    for _ in $(seq 1 90); do
        ready=$(fuzz_scalar \
            "SELECT count(*) = ${FUZZ_WORKERS} AND bool_and(s.status='running' AND a.pid IS NOT NULL) FROM pgs3.worker_state s LEFT JOIN pg_stat_activity a ON a.pid=s.pid AND a.backend_type='pgs3 http' WHERE s.worker_kind='http' AND s.desired" \
            2>/dev/null || true)
        if [[ ${ready} == t ]]; then
            docker exec "${FUZZ_CONTAINER}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --command 'TABLE pgs3.worker_state'
            return 0
        fi
        sleep 1
    done
    docker exec "${FUZZ_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --command 'TABLE pgs3.worker_state' || true
    printf 'HTTP worker pool did not converge to %s workers\n' "${FUZZ_WORKERS}" >&2
    return 1
}

fuzz_wait_port() {
    PGS3_FUZZ_WAIT_PORT=${FUZZ_HOST_PORT} python3 - <<'PY'
import os
import socket
import time

port = int(os.environ["PGS3_FUZZ_WAIT_PORT"])
deadline = time.monotonic() + 30
last = None
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            print(f"S3 endpoint is accepting connections on 127.0.0.1:{port}")
            raise SystemExit(0)
    except OSError as error:
        last = error
        time.sleep(0.2)
raise SystemExit(f"S3 endpoint did not become ready: {last}")
PY
}

fuzz_runtime_record() {
    fuzz_scalar "
        WITH h AS (
            SELECT s.pid, s.status, a.pid AS active_pid
              FROM pgs3.worker_state s
              LEFT JOIN pg_stat_activity a
                ON a.pid = s.pid AND a.backend_type = 'pgs3 http'
             WHERE s.worker_kind = 'http' AND s.desired
        )
        SELECT extract(epoch FROM pg_postmaster_start_time())::text || '|' ||
               (SELECT count(*)::text FROM h) || '|' ||
               (SELECT COALESCE(string_agg(pid::text, ',' ORDER BY pid), '') FROM h) || '|' ||
               (SELECT COALESCE(bool_and(status='running' AND active_pid IS NOT NULL), false)::text FROM h) || '|' ||
               (SELECT count(*)::text FROM pg_stat_activity WHERE backend_type='pgs3 launcher')
    "
}

fuzz_capture_baseline() {
    local record count healthy launcher
    record=$(fuzz_runtime_record)
    IFS='|' read -r FUZZ_BASE_POSTMASTER_START count FUZZ_BASE_WORKER_PIDS healthy launcher <<<"${record}"
    FUZZ_BASE_CONTAINER_PID=$(docker container inspect "${FUZZ_CONTAINER}" \
        --format '{{.State.Pid}}')
    printf 'runtime baseline: postmaster_start=%s workers=%s pids=%s healthy=%s launcher=%s container_pid=%s\n' \
        "${FUZZ_BASE_POSTMASTER_START}" "${count}" "${FUZZ_BASE_WORKER_PIDS}" \
        "${healthy}" "${launcher}" "${FUZZ_BASE_CONTAINER_PID}"
    [[ ${count} == "${FUZZ_WORKERS}" ]]
    [[ ${healthy} == true ]]
    [[ ${launcher} == 1 ]]
    [[ ${FUZZ_BASE_WORKER_PIDS} =~ ^[0-9]+(,[0-9]+)*$ ]]
    [[ ${FUZZ_BASE_CONTAINER_PID} =~ ^[1-9][0-9]*$ ]]
}

fuzz_assert_runtime() {
    local container_state record start count pids healthy launcher pid
    container_state=$(docker container inspect "${FUZZ_CONTAINER}" \
        --format '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}')
    printf 'container state: %s\n' "${container_state}"
    [[ ${container_state} == "true|${FUZZ_BASE_CONTAINER_PID}|0" ]]
    docker exec "${FUZZ_CONTAINER}" pg_isready \
        --username postgres --dbname postgres
    record=$(fuzz_runtime_record)
    IFS='|' read -r start count pids healthy launcher <<<"${record}"
    printf 'runtime identity: postmaster_start=%s workers=%s pids=%s healthy=%s launcher=%s\n' \
        "${start}" "${count}" "${pids}" "${healthy}" "${launcher}"
    [[ ${start} == "${FUZZ_BASE_POSTMASTER_START}" ]]
    [[ ${count} == "${FUZZ_WORKERS}" ]]
    [[ ${pids} == "${FUZZ_BASE_WORKER_PIDS}" ]]
    [[ ${healthy} == true ]]
    [[ ${launcher} == 1 ]]
    IFS=',' read -r -a worker_pids <<<"${pids}"
    for pid in "${worker_pids[@]}"; do
        docker exec "${FUZZ_CONTAINER}" test -r "/proc/${pid}/stat"
    done
}

fuzz_client() {
    PYTHONDONTWRITEBYTECODE=1 python3 "${fuzz_dir}/malformed_client.py" "$@"
}

fuzz_common_client_arguments() {
    printf '%s\n' \
        --endpoint "http://127.0.0.1:${FUZZ_HOST_PORT}" \
        --bucket "${FUZZ_BUCKET}" \
        --key "${FUZZ_SENTINEL_KEY}" \
        --seed "${FUZZ_SEED}" \
        --random-cases "${FUZZ_RANDOM_CASES}" \
        --timeout "${FUZZ_CASE_TIMEOUT}"
}

fuzz_setup_sentinel() {
    local -a common
    mapfile -t common < <(fuzz_common_client_arguments)
    fuzz_client setup "${common[@]}"
}

fuzz_probe_sentinel() {
    local -a common
    mapfile -t common < <(fuzz_common_client_arguments)
    fuzz_client probe "${common[@]}"
}

fuzz_run_case() {
    local case_name=$1
    local -a common
    [[ ${case_name} =~ ^[a-z0-9][a-z0-9-]*$ ]]
    mapfile -t common < <(fuzz_common_client_arguments)
    fuzz_client case "${common[@]}" \
        --case "${case_name}" \
        --scratch-bucket "${FUZZ_SCRATCH_BUCKET}"
}

fuzz_cleanup_sentinel() {
    local -a common
    mapfile -t common < <(fuzz_common_client_arguments)
    fuzz_client cleanup "${common[@]}"
}

fuzz_materialize_cases() {
    fuzz_client names \
        --seed "${FUZZ_SEED}" \
        --random-cases "${FUZZ_RANDOM_CASES}" \
        --timeout "${FUZZ_CASE_TIMEOUT}" >"${FUZZ_CASE_FILE}"
    [[ -s ${FUZZ_CASE_FILE} ]]
    if grep -Ev '^[a-z0-9][a-z0-9-]*$' "${FUZZ_CASE_FILE}"; then
        printf 'corpus emitted an unsafe case name\n' >&2
        return 1
    fi
    if sort "${FUZZ_CASE_FILE}" | uniq -d | grep -q .; then
        printf 'corpus emitted a duplicate case name\n' >&2
        return 1
    fi
}

fuzz_safe_remove_container() {
    local label
    if [[ -z ${FUZZ_CONTAINER} ]] || ! docker container inspect "${FUZZ_CONTAINER}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker container inspect "${FUZZ_CONTAINER}" \
        --format '{{index .Config.Labels "pgs3.fuzz.run"}}')
    if [[ ${label} != "${FUZZ_RUN_TAG}" ]]; then
        printf 'refusing to remove container with unexpected fuzz label: %s\n' \
            "${FUZZ_CONTAINER}" >&2
        return 1
    fi
    evidence_run fuzz-container-remove docker rm --force --volumes "${FUZZ_CONTAINER}"
}

fuzz_safe_remove_network() {
    local label
    if [[ -z ${FUZZ_NETWORK} ]] || ! docker network inspect "${FUZZ_NETWORK}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker network inspect "${FUZZ_NETWORK}" \
        --format '{{index .Labels "pgs3.fuzz.run"}}')
    if [[ ${label} != "${FUZZ_RUN_TAG}" ]]; then
        printf 'refusing to remove network with unexpected fuzz label: %s\n' \
            "${FUZZ_NETWORK}" >&2
        return 1
    fi
    evidence_run fuzz-network-remove docker network rm "${FUZZ_NETWORK}"
}

fuzz_assert_artifacts_redacted() {
    python3 - "${PGS3_RUN_DIR}" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
values = {
    os.environ.get("PGS3_FUZZ_ACCESS_KEY", "").encode(),
    os.environ.get("PGS3_FUZZ_SECRET", "").encode(),
}
values.discard(b"")
leaks = []
files = 0
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    files += 1
    data = path.read_bytes()
    if any(value in data for value in values):
        leaks.append(str(path.relative_to(root)))
if leaks:
    print("unredacted fuzz credential material found in: " + ", ".join(sorted(leaks)))
    raise SystemExit(1)
print(f"fuzz redaction audit passed for {files} evidence files")
PY
}

fuzz_cleanup() {
    local original_status=$?
    local cleanup_rc
    trap - EXIT INT TERM
    set +e

    if [[ -n ${FUZZ_CONTAINER} ]] && docker container inspect "${FUZZ_CONTAINER}" >/dev/null 2>&1; then
        if [[ -n ${FUZZ_BASE_POSTMASTER_START} ]]; then
            evidence_try fuzz-final-runtime fuzz_assert_runtime
            ((PGS3_EVIDENCE_LAST_RC == 0)) || FUZZ_CLEANUP_FAILED=1
        fi
        evidence_try fuzz-postgres-logs docker logs "${FUZZ_CONTAINER}"
        ((PGS3_EVIDENCE_LAST_RC == 0)) || FUZZ_CLEANUP_FAILED=1
    fi
    fuzz_safe_remove_container
    cleanup_rc=$?
    ((cleanup_rc == 0)) || FUZZ_CLEANUP_FAILED=1
    fuzz_safe_remove_network
    cleanup_rc=$?
    ((cleanup_rc == 0)) || FUZZ_CLEANUP_FAILED=1

    if [[ -n ${FUZZ_TMP_DIR} && -d ${FUZZ_TMP_DIR} ]]; then
        case ${FUZZ_TMP_DIR} in
            "${TMPDIR:-/tmp}"/pgs3-fuzz.*) rm -rf -- "${FUZZ_TMP_DIR}" ;;
            *)
                printf 'refusing to remove unexpected fuzz temporary directory: %s\n' \
                    "${FUZZ_TMP_DIR}" >&2
                FUZZ_CLEANUP_FAILED=1
                ;;
        esac
    fi

    evidence_try fuzz-final-redaction-audit fuzz_assert_artifacts_redacted
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        FUZZ_CLEANUP_FAILED=1
        FUZZ_RESULT=FAIL
        original_status=1
    fi
    if [[ ${FUZZ_RESULT} == RUNNING ]]; then
        FUZZ_RESULT=FAIL
    fi
    if ((original_status != 0)) && [[ ${FUZZ_RESULT} == PASS ]]; then
        FUZZ_RESULT=FAIL
    fi
    if ((FUZZ_CLEANUP_FAILED)) && [[ ${FUZZ_RESULT} == PASS ]]; then
        FUZZ_RESULT=FAIL
        original_status=1
    fi
    evidence_finalize "${FUZZ_RESULT}" || original_status=1
    evidence_cleanup
    printf 'fuzz acceptance result: %s\nmanifest: %s/manifest.json\n' \
        "${FUZZ_RESULT}" "${PGS3_RUN_DIR}"
    exit "${original_status}"
}
