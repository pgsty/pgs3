#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # shared state is consumed by run.sh and the EXIT trap

robust_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${robust_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local evidence helper
source "${repo_dir}/scripts/lib/evidence.sh"

export PGS3_ROBUST_ACCESS_KEY=${PGS3_ROBUST_ACCESS_KEY:-PGS3ROBUSTACCESS01}
if [[ -z ${PGS3_ROBUST_SECRET:-} ]]; then
    PGS3_ROBUST_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    export PGS3_ROBUST_SECRET
fi
export PGS3_REDACT_ENV_NAMES="${PGS3_REDACT_ENV_NAMES:+${PGS3_REDACT_ENV_NAMES},}PGS3_ROBUST_ACCESS_KEY,PGS3_ROBUST_SECRET"

ROBUST_RESULT=RUNNING
ROBUST_CLEANUP_FAILED=0
ROBUST_RUN_TAG=''
ROBUST_TMP_DIR=''
ROBUST_NETWORK=''
ROBUST_CONTAINER=''
ROBUST_IMAGE=''
ROBUST_HOST_PORT=''
ROBUST_WORKERS=''
ROBUST_BUCKET=''
ROBUST_SCRATCH_BUCKET=''
ROBUST_SENTINEL_KEY='sentinel/healthy.bin'
ROBUST_BASE_POSTMASTER_START=''
ROBUST_BASE_HTTP_ACTIVITY=''
ROBUST_BASE_HTTP_DESIRED=''
ROBUST_BASE_WORKER_PIDS=''
ROBUST_BASE_CONTAINER_PID=''

robust_require_command() {
    local command=$1
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'required command is unavailable: %s\n' "${command}" >&2
        return 127
    fi
}

robust_pick_port() {
    python3 - <<'PY'
import socket

with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

robust_init_runtime() {
    ROBUST_RUN_TAG=$(PGS3_ROBUST_TAG_SOURCE="${PGS3_RUN_DIR}" python3 - <<'PY'
import hashlib
import os

print(hashlib.sha256(os.environ["PGS3_ROBUST_TAG_SOURCE"].encode()).hexdigest()[:12])
PY
)
    ROBUST_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pgs3-robustness.XXXXXXXX")
    ROBUST_NETWORK="pgs3-robust-net-${ROBUST_RUN_TAG}"
    ROBUST_CONTAINER="pgs3-robust-${ROBUST_RUN_TAG}"
    ROBUST_HOST_PORT=$(robust_pick_port)
    ROBUST_BUCKET="robust-${ROBUST_RUN_TAG}"
    ROBUST_SCRATCH_BUCKET="robust-xml-${ROBUST_RUN_TAG}"
    evidence_run robustness-network-create docker network create \
        --label "pgs3.robustness.run=${ROBUST_RUN_TAG}" \
        "${ROBUST_NETWORK}"
}

robust_start_server() {
    evidence_run robustness-server-start docker run --detach \
        --pull never \
        --name "${ROBUST_CONTAINER}" \
        --label "pgs3.robustness.run=${ROBUST_RUN_TAG}" \
        --network "${ROBUST_NETWORK}" \
        --publish "127.0.0.1:${ROBUST_HOST_PORT}:9000/tcp" \
        --restart no \
        --env POSTGRES_HOST_AUTH_METHOD=trust \
        --shm-size 256m \
        "${ROBUST_IMAGE}" \
        postgres \
        -c shared_preload_libraries=pgs3 \
        -c max_worker_processes=32 \
        -c pgs3.enabled=off \
        -c pgs3.listen_addr=0.0.0.0 \
        -c pgs3.port=9000 \
        -c "pgs3.workers=${ROBUST_WORKERS}" \
        -c pgs3.statement_timeout_ms=3000 \
        -c log_min_messages=info \
        -c 'log_line_prefix=%m [%p] %q%u@%d '
}

robust_assert_scope() {
    local container_scope network_scope
    container_scope=$(docker container inspect "${ROBUST_CONTAINER}" --format \
        '{{.HostConfig.NetworkMode}}|{{(index (index .HostConfig.PortBindings "9000/tcp") 0).HostIp}}|{{(index (index .HostConfig.PortBindings "9000/tcp") 0).HostPort}}|{{.HostConfig.RestartPolicy.Name}}|{{index .Config.Labels "pgs3.robustness.run"}}')
    network_scope=$(docker network inspect "${ROBUST_NETWORK}" --format \
        '{{.Internal}}|{{index .Labels "pgs3.robustness.run"}}')
    printf 'container runtime scope: %s\nnetwork runtime scope: %s\n' \
        "${container_scope}" "${network_scope}"
    [[ ${container_scope} == "${ROBUST_NETWORK}|127.0.0.1|${ROBUST_HOST_PORT}|no|${ROBUST_RUN_TAG}" ]]
    [[ ${network_scope} == "false|${ROBUST_RUN_TAG}" ]]
}

robust_wait_postgres() {
    local last=''
    printf 'waiting for PostgreSQL in disposable container %s\n' "${ROBUST_CONTAINER}"
    for _ in $(seq 1 120); do
        if docker exec "${ROBUST_CONTAINER}" pg_isready \
            --username postgres --dbname postgres >/dev/null 2>&1; then
            docker exec "${ROBUST_CONTAINER}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --tuples-only --no-align --command \
                "SELECT current_setting('server_version'), pg_postmaster_start_time()"
            return 0
        fi
        last=$(docker container inspect "${ROBUST_CONTAINER}" \
            --format '{{.State.Status}}|{{.State.ExitCode}}|{{.State.Error}}' \
            2>/dev/null || true)
        sleep 1
    done
    printf 'PostgreSQL did not become ready in 120 seconds: %s\n' "${last}" >&2
    return 1
}

robust_bootstrap_extension() {
    docker exec --interactive \
        --env PGS3_ROBUST_ACCESS_KEY \
        --env PGS3_ROBUST_SECRET \
        "${ROBUST_CONTAINER}" \
        bash -Eeuo pipefail -c '
            psql --username postgres --dbname postgres --no-psqlrc \
                --set ON_ERROR_STOP=1 \
                --set access_key="$PGS3_ROBUST_ACCESS_KEY" \
                --set secret="$PGS3_ROBUST_SECRET"
        ' <<'SQL'
CREATE EXTENSION pgs3;
CREATE ROLE pgs3_robust_tenant
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;
SELECT pgs3.create_credential(
    :'access_key', :'secret', 'pgs3_robust_tenant'::name, true
);
SELECT pgs3.start();
SQL
}

robust_scalar() {
    local sql=$1
    docker exec "${ROBUST_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --tuples-only --no-align --set ON_ERROR_STOP=1 \
        --command "${sql}" | tr -d '[:space:]'
}

robust_wait_workers() {
    local ready=''
    for _ in $(seq 1 90); do
        ready=$(robust_scalar "
            WITH desired AS (
                SELECT s.pid, s.status, a.pid AS active_pid
                  FROM pgs3.worker_state AS s
                  LEFT JOIN pg_stat_activity AS a
                    ON a.pid = s.pid AND a.backend_type = 'pgs3 http'
                 WHERE s.worker_kind = 'http' AND s.desired
            )
            SELECT (SELECT count(*) FROM desired) = ${ROBUST_WORKERS}
               AND (SELECT count(*) FROM pg_stat_activity
                     WHERE backend_type = 'pgs3 http') = ${ROBUST_WORKERS}
               AND (SELECT bool_and(status = 'running' AND active_pid IS NOT NULL)
                      FROM desired)
        " 2>/dev/null || true)
        if [[ ${ready} == t ]]; then
            docker exec "${ROBUST_CONTAINER}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --command 'TABLE pgs3.worker_state'
            return 0
        fi
        sleep 1
    done
    docker exec "${ROBUST_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --command 'TABLE pgs3.worker_state' || true
    printf 'HTTP worker pool did not converge to %s workers\n' "${ROBUST_WORKERS}" >&2
    return 1
}

robust_wait_port() {
    PGS3_ROBUST_WAIT_PORT=${ROBUST_HOST_PORT} python3 - <<'PY'
import os
import socket
import time

port = int(os.environ["PGS3_ROBUST_WAIT_PORT"])
deadline = time.monotonic() + 30.0
last = None
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            print(f"S3 endpoint is accepting connections on 127.0.0.1:{port}")
            raise SystemExit(0)
    except OSError as error:
        last = error
        time.sleep(0.2)
raise SystemExit(f"local S3 endpoint did not become ready: {last}")
PY
}

robust_runtime_record() {
    robust_scalar "
        WITH desired AS (
            SELECT s.pid, s.status, a.pid AS active_pid
              FROM pgs3.worker_state AS s
              LEFT JOIN pg_stat_activity AS a
                ON a.pid = s.pid AND a.backend_type = 'pgs3 http'
             WHERE s.worker_kind = 'http' AND s.desired
        )
        SELECT extract(epoch FROM pg_postmaster_start_time())::text || '|' ||
               (SELECT count(*)::text FROM pg_stat_activity
                 WHERE backend_type = 'pgs3 http') || '|' ||
               (SELECT count(*)::text FROM desired) || '|' ||
               (SELECT COALESCE(bool_and(status = 'running' AND active_pid IS NOT NULL), false)::text
                  FROM desired) || '|' ||
               (SELECT COALESCE(string_agg(pid::text, ',' ORDER BY pid), '')
                  FROM desired) || '|' ||
               (SELECT count(*)::text FROM pg_stat_activity
                 WHERE backend_type = 'pgs3 launcher')
    "
}

robust_capture_baseline() {
    local record healthy launcher
    record=$(robust_runtime_record)
    IFS='|' read -r ROBUST_BASE_POSTMASTER_START ROBUST_BASE_HTTP_ACTIVITY \
        ROBUST_BASE_HTTP_DESIRED healthy ROBUST_BASE_WORKER_PIDS launcher \
        <<<"${record}"
    ROBUST_BASE_CONTAINER_PID=$(docker container inspect "${ROBUST_CONTAINER}" \
        --format '{{.State.Pid}}')
    printf 'runtime baseline: postmaster_start=%s active_http=%s desired_http=%s healthy=%s pids=%s launcher=%s container_pid=%s\n' \
        "${ROBUST_BASE_POSTMASTER_START}" "${ROBUST_BASE_HTTP_ACTIVITY}" \
        "${ROBUST_BASE_HTTP_DESIRED}" "${healthy}" \
        "${ROBUST_BASE_WORKER_PIDS}" "${launcher}" \
        "${ROBUST_BASE_CONTAINER_PID}"
    [[ ${ROBUST_BASE_HTTP_ACTIVITY} == "${ROBUST_WORKERS}" ]]
    [[ ${ROBUST_BASE_HTTP_DESIRED} == "${ROBUST_WORKERS}" ]]
    [[ ${healthy} == true ]]
    [[ ${launcher} == 1 ]]
    [[ ${ROBUST_BASE_WORKER_PIDS} =~ ^[0-9]+(,[0-9]+)*$ ]]
    [[ ${ROBUST_BASE_CONTAINER_PID} =~ ^[1-9][0-9]*$ ]]
}

robust_assert_runtime() {
    local container_state record start active desired healthy pids launcher
    container_state=$(docker container inspect "${ROBUST_CONTAINER}" \
        --format '{{.State.Running}}|{{.State.Pid}}|{{.RestartCount}}')
    printf 'container state: %s\n' "${container_state}"
    [[ ${container_state} == "true|${ROBUST_BASE_CONTAINER_PID}|0" ]]
    docker exec "${ROBUST_CONTAINER}" pg_isready \
        --username postgres --dbname postgres
    record=$(robust_runtime_record)
    IFS='|' read -r start active desired healthy pids launcher <<<"${record}"
    printf 'runtime invariant: postmaster_start=%s active_http=%s desired_http=%s healthy=%s pids=%s launcher=%s\n' \
        "${start}" "${active}" "${desired}" "${healthy}" "${pids}" "${launcher}"
    [[ ${start} == "${ROBUST_BASE_POSTMASTER_START}" ]]
    [[ ${active} == "${ROBUST_BASE_HTTP_ACTIVITY}" ]]
    [[ ${desired} == "${ROBUST_BASE_HTTP_DESIRED}" ]]
    [[ ${active} == "${ROBUST_WORKERS}" ]]
    [[ ${desired} == "${ROBUST_WORKERS}" ]]
    [[ ${healthy} == true ]]
    [[ ${pids} == "${ROBUST_BASE_WORKER_PIDS}" ]]
    [[ ${launcher} == 1 ]]
    local -a worker_pids
    local pid
    IFS=',' read -r -a worker_pids <<<"${pids}"
    for pid in "${worker_pids[@]}"; do
        docker exec "${ROBUST_CONTAINER}" test -r "/proc/${pid}/stat"
    done
}

robust_client() {
    PYTHONDONTWRITEBYTECODE=1 python3 "${robust_dir}/http_boundary.py" "$@"
}

robust_setup_sentinel() {
    local -a common
    common=(
        --endpoint "http://127.0.0.1:${ROBUST_HOST_PORT}"
        --bucket "${ROBUST_BUCKET}"
        --key "${ROBUST_SENTINEL_KEY}"
    )
    robust_client setup "${common[@]}"
}

robust_probe_sentinel() {
    local -a common
    common=(
        --endpoint "http://127.0.0.1:${ROBUST_HOST_PORT}"
        --bucket "${ROBUST_BUCKET}"
        --key "${ROBUST_SENTINEL_KEY}"
    )
    robust_client probe "${common[@]}"
}

robust_run_batch() {
    local batch=$1
    [[ ${batch} =~ ^[a-z][a-z-]*$ ]]
    robust_client batch \
        --endpoint "http://127.0.0.1:${ROBUST_HOST_PORT}" \
        --bucket "${ROBUST_BUCKET}" \
        --key "${ROBUST_SENTINEL_KEY}" \
        --batch "${batch}" \
        --scratch-bucket "${ROBUST_SCRATCH_BUCKET}"
}

robust_safe_remove_container() {
    local label
    if [[ -z ${ROBUST_CONTAINER} ]] \
        || ! docker container inspect "${ROBUST_CONTAINER}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker container inspect "${ROBUST_CONTAINER}" \
        --format '{{index .Config.Labels "pgs3.robustness.run"}}')
    if [[ ${label} != "${ROBUST_RUN_TAG}" ]]; then
        printf 'refusing to remove container with unexpected robustness label: %s\n' \
            "${ROBUST_CONTAINER}" >&2
        return 1
    fi
    evidence_run robustness-container-remove docker rm --force --volumes \
        "${ROBUST_CONTAINER}"
}

robust_safe_remove_network() {
    local label
    if [[ -z ${ROBUST_NETWORK} ]] \
        || ! docker network inspect "${ROBUST_NETWORK}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker network inspect "${ROBUST_NETWORK}" \
        --format '{{index .Labels "pgs3.robustness.run"}}')
    if [[ ${label} != "${ROBUST_RUN_TAG}" ]]; then
        printf 'refusing to remove network with unexpected robustness label: %s\n' \
            "${ROBUST_NETWORK}" >&2
        return 1
    fi
    evidence_run robustness-network-remove docker network rm "${ROBUST_NETWORK}"
}

robust_assert_artifacts_redacted() {
    python3 - "${PGS3_RUN_DIR}" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
values = {
    os.environ.get("PGS3_ROBUST_ACCESS_KEY", "").encode(),
    os.environ.get("PGS3_ROBUST_SECRET", "").encode(),
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
    print("unredacted robustness credential material found in: " + ", ".join(sorted(leaks)))
    raise SystemExit(1)
print(f"robustness redaction audit passed for {files} evidence files")
PY
}

robust_cleanup() {
    local original_status=$?
    local cleanup_rc
    trap - EXIT INT TERM
    set +e

    if [[ -n ${ROBUST_CONTAINER} ]] \
        && docker container inspect "${ROBUST_CONTAINER}" >/dev/null 2>&1; then
        if [[ -n ${ROBUST_BASE_POSTMASTER_START} ]]; then
            evidence_try robustness-final-runtime robust_assert_runtime
            ((PGS3_EVIDENCE_LAST_RC == 0)) || ROBUST_CLEANUP_FAILED=1
        fi
        evidence_try robustness-postgres-logs docker logs "${ROBUST_CONTAINER}"
        ((PGS3_EVIDENCE_LAST_RC == 0)) || ROBUST_CLEANUP_FAILED=1
    fi

    robust_safe_remove_container
    cleanup_rc=$?
    ((cleanup_rc == 0)) || ROBUST_CLEANUP_FAILED=1
    robust_safe_remove_network
    cleanup_rc=$?
    ((cleanup_rc == 0)) || ROBUST_CLEANUP_FAILED=1

    if [[ -n ${ROBUST_TMP_DIR} && -d ${ROBUST_TMP_DIR} ]]; then
        case ${ROBUST_TMP_DIR} in
            "${TMPDIR:-/tmp}"/pgs3-robustness.*)
                rm -rf -- "${ROBUST_TMP_DIR}"
                ;;
            *)
                printf 'refusing to remove unexpected robustness temporary directory: %s\n' \
                    "${ROBUST_TMP_DIR}" >&2
                ROBUST_CLEANUP_FAILED=1
                ;;
        esac
    fi

    evidence_try robustness-final-redaction-audit robust_assert_artifacts_redacted
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        ROBUST_CLEANUP_FAILED=1
        ROBUST_RESULT=FAIL
        original_status=1
    fi
    if [[ ${ROBUST_RESULT} == RUNNING ]]; then
        ROBUST_RESULT=FAIL
    fi
    if ((original_status != 0)) && [[ ${ROBUST_RESULT} == PASS ]]; then
        ROBUST_RESULT=FAIL
    fi
    if ((ROBUST_CLEANUP_FAILED)) && [[ ${ROBUST_RESULT} == PASS ]]; then
        ROBUST_RESULT=FAIL
        original_status=1
    fi
    evidence_finalize "${ROBUST_RESULT}" || original_status=1
    evidence_cleanup
    printf 'robustness result: %s\nmanifest: %s/manifest.json\n' \
        "${ROBUST_RESULT}" "${PGS3_RUN_DIR}"
    exit "${original_status}"
}
