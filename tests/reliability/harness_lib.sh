#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # state is consumed by sourced callers

reliability_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${reliability_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-relative helper
source "${repo_dir}/scripts/lib/evidence.sh"

export PGS3_TEST_ACCESS_KEY_A=${PGS3_TEST_ACCESS_KEY_A:-PGS3RELACCESS000001}
if [[ -z ${PGS3_TEST_SECRET_A:-} ]]; then
    PGS3_TEST_SECRET_A=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    export PGS3_TEST_SECRET_A
fi
export PGS3_REDACT_ENV_NAMES="${PGS3_REDACT_ENV_NAMES:+${PGS3_REDACT_ENV_NAMES},}PGS3_TEST_ACCESS_KEY_A,PGS3_TEST_SECRET_A"

# These variables are shared with run.sh and scenarios.sh after this file is
# sourced.  ShellCheck analyzes this library independently in the static gate.
REL_RESULT=RUNNING
REL_CLEANUP_FAILED=0
REL_NETWORK=''
REL_RUN_TAG=''
REL_TMP_DIR=''
REL_IMAGE=''
REL_PG_MAJOR=''
REL_LAST_VOLUME=''
REL_LAST_CONTAINER=''
declare -a REL_CONTAINERS=()
declare -a REL_VOLUMES=()
declare -a REL_HOST_PIDS=()

rel_require_command() {
    local command=$1
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'required command is unavailable: %s\n' "${command}" >&2
        return 127
    fi
}

rel_pick_port() {
    python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

rel_init_runtime() {
    REL_RUN_TAG=$(printf '%s' "${PGS3_RUN_DIR}" | sha256sum | cut -c1-12)
    REL_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pgs3-reliability.XXXXXXXX")
    REL_NETWORK="pgs3-rel-net-${REL_RUN_TAG}"
    evidence_run network-create docker network create \
        --label "pgs3.reliability.run=${REL_RUN_TAG}" \
        "${REL_NETWORK}"
}

rel_create_volume() {
    local suffix=$1
    local name="pgs3-rel-${suffix}-${REL_RUN_TAG}"
    if docker volume inspect "${name}" >/dev/null 2>&1; then
        printf 'refusing to reuse pre-existing reliability volume: %s\n' "${name}" >&2
        return 1
    fi
    REL_VOLUMES+=("${name}")
    evidence_run "volume-create-${suffix}" docker volume create \
        --label "pgs3.reliability.run=${REL_RUN_TAG}" \
        "${name}"
    REL_LAST_VOLUME=${name}
}

rel_track_container() {
    REL_CONTAINERS+=("$1")
}

rel_track_host_pid() {
    REL_HOST_PIDS+=("$1")
}

rel_wait_postgres() {
    local container=$1
    printf 'waiting for PostgreSQL in %s\n' "${container}"
    for _ in $(seq 1 120); do
        if docker exec "${container}" pg_isready \
            --username postgres --dbname postgres >/dev/null 2>&1; then
            docker exec "${container}" psql --username postgres --dbname postgres \
                --no-psqlrc --tuples-only --no-align \
                --command "SELECT current_setting('server_version'), pg_is_in_recovery(), pg_postmaster_start_time()"
            return 0
        fi
        sleep 1
    done
    printf 'PostgreSQL was not ready after 120 seconds: %s\n' "${container}" >&2
    return 1
}

rel_wait_port() {
    local port=$1
    PGS3_RELIABILITY_PORT=${port} python3 - <<'PY'
import os
import socket
import time

port = int(os.environ["PGS3_RELIABILITY_PORT"])
deadline = time.monotonic() + 30
last = None
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=0.5):
            print(f"TCP endpoint is accepting connections on 127.0.0.1:{port}")
            raise SystemExit(0)
    except OSError as error:
        last = error
        time.sleep(0.2)
raise SystemExit(f"TCP endpoint did not become ready on port {port}: {last}")
PY
}

rel_wait_container_listener_gone() {
    local container=$1 port=$2 port_hex status
    local consecutive_absences=0
    printf -v port_hex '%04X' "${port}"
    for _ in $(seq 1 50); do
        if docker exec "${container}" awk -v wanted="${port_hex}" '
            $4 == "0A" {
                split($2, endpoint, ":")
                if (toupper(endpoint[2]) == wanted) {
                    found = 1
                }
            }
            END { exit found ? 0 : 3 }
        ' /proc/net/tcp >/dev/null; then
            consecutive_absences=0
        else
            status=$?
            if ((status != 3)); then
                printf 'failed to inspect listeners in %s: exit_status=%s\n' \
                    "${container}" "${status}" >&2
                return "${status}"
            fi
            consecutive_absences=$((consecutive_absences + 1))
            if ((consecutive_absences >= 5)); then
                printf 'container listener is absent: container=%s port=%s\n' \
                    "${container}" "${port}"
                return 0
            fi
        fi
        sleep 0.1
    done
    printf 'container listener remained present: container=%s port=%s\n' \
        "${container}" "${port}" >&2
    docker exec "${container}" cat /proc/net/tcp >&2
    return 1
}

rel_scalar() {
    local container=$1 sql=$2
    docker exec "${container}" psql --username postgres --dbname postgres \
        --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 \
        --command "${sql}" | tr -d '[:space:]'
}

rel_assert_scalar() {
    local container=$1 sql=$2 expected=$3 description=$4 actual
    actual=$(rel_scalar "${container}" "${sql}")
    printf '%s: expected=%s actual=%s\n' "${description}" "${expected}" "${actual}"
    [[ ${actual} == "${expected}" ]]
}

rel_wait_scalar() {
    local container=$1 sql=$2 expected=$3 description=$4 attempts=${5:-60} actual=''
    for _ in $(seq 1 "${attempts}"); do
        actual=$(rel_scalar "${container}" "${sql}" 2>/dev/null || true)
        if [[ ${actual} == "${expected}" ]]; then
            printf '%s: expected=%s actual=%s\n' "${description}" "${expected}" "${actual}"
            return 0
        fi
        sleep 1
    done
    printf '%s: expected=%s actual=%s\n' "${description}" "${expected}" "${actual}" >&2
    return 1
}

rel_bootstrap_extension() {
    local container=$1
    docker exec --interactive \
        --env PGS3_TEST_ACCESS_KEY_A \
        --env PGS3_TEST_SECRET_A \
        "${container}" \
        bash -Eeuo pipefail -c '
            psql --username postgres --dbname postgres --no-psqlrc \
                --set ON_ERROR_STOP=1 \
                --set access_key="$PGS3_TEST_ACCESS_KEY_A" \
                --set secret="$PGS3_TEST_SECRET_A"
        ' <<'SQL'
CREATE EXTENSION pgs3;
CREATE ROLE pgs3_reliability_tenant
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE
    NOREPLICATION NOBYPASSRLS;
SELECT pgs3.create_credential(
    :'access_key', :'secret', 'pgs3_reliability_tenant'::name, true
);
SQL
}

rel_configure_static() {
    local container=$1 listen_addr=$2 port=$3 workers=$4 statement_timeout=$5
    docker exec --interactive "${container}" psql \
        --username postgres --dbname postgres --no-psqlrc --set ON_ERROR_STOP=1 \
        --set listen_addr="${listen_addr}" \
        --set port="${port}" \
        --set workers="${workers}" \
        --set statement_timeout="${statement_timeout}" <<'SQL'
ALTER SYSTEM SET pgs3.enabled = 'on';
ALTER SYSTEM SET pgs3.target_database = 'postgres';
ALTER SYSTEM SET pgs3.listen_addr = :'listen_addr';
ALTER SYSTEM SET pgs3.port = :'port';
ALTER SYSTEM SET pgs3.workers = :'workers';
ALTER SYSTEM SET pgs3.statement_timeout_ms = :'statement_timeout';
SQL
    docker restart --time 10 "${container}"
    rel_wait_postgres "${container}"
}

rel_wait_primary_workers() {
    local container=$1 workers=$2 port=$3 listen_addr=$4
    local escaped_addr=${listen_addr//\'/\'\'}
    rel_wait_scalar "${container}" \
        "SELECT (count(*) = ${workers} AND bool_and(s.port = ${port} AND s.listen_addr = '${escaped_addr}' AND a.pid IS NOT NULL)) FROM pgs3.worker_state s LEFT JOIN pg_stat_activity a ON a.pid=s.pid AND a.backend_type='pgs3 http' WHERE s.worker_kind='http' AND s.desired AND s.status='running'" \
        t "HTTP worker pool converged" 90
}

rel_wait_standby_workers() {
    local container=$1 workers=$2
    rel_wait_scalar "${container}" \
        "SELECT count(*) = ${workers} FROM pg_stat_activity WHERE backend_type = 'pgs3 http'" \
        t "standby dynamic HTTP workers started" 90
}

rel_endpoint() {
    printf 'http://127.0.0.1:%s' "$1"
}

rel_s3() {
    PYTHONDONTWRITEBYTECODE=1 python3 "${reliability_dir}/s3_client.py" "$@"
}

rel_container_ip() {
    docker inspect "$1" --format "{{with index .NetworkSettings.Networks \"${REL_NETWORK}\"}}{{.IPAddress}}{{end}}"
}

rel_safe_remove_container() {
    local container=$1 label
    if ! docker container inspect "${container}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker container inspect "${container}" \
        --format '{{index .Config.Labels "pgs3.reliability.run"}}')
    if [[ ${label} != "${REL_RUN_TAG}" ]]; then
        printf 'refusing to remove container with unexpected label: %s\n' "${container}" >&2
        return 1
    fi
    evidence_try "logs-${container}" docker logs "${container}"
    ((PGS3_EVIDENCE_LAST_RC == 0)) || REL_CLEANUP_FAILED=1
    evidence_run "remove-${container}" docker rm --force --volumes "${container}"
}

rel_safe_remove_volume() {
    local volume=$1 label
    if ! docker volume inspect "${volume}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker volume inspect "${volume}" \
        --format '{{index .Labels "pgs3.reliability.run"}}')
    if [[ ${label} != "${REL_RUN_TAG}" ]]; then
        printf 'refusing to remove volume with unexpected label: %s\n' "${volume}" >&2
        return 1
    fi
    evidence_run "remove-${volume}" docker volume rm "${volume}"
}

rel_safe_remove_network() {
    local label
    if [[ -z ${REL_NETWORK} ]] || ! docker network inspect "${REL_NETWORK}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker network inspect "${REL_NETWORK}" \
        --format '{{index .Labels "pgs3.reliability.run"}}')
    if [[ ${label} != "${REL_RUN_TAG}" ]]; then
        printf 'refusing to remove network with unexpected label: %s\n' "${REL_NETWORK}" >&2
        return 1
    fi
    evidence_run network-remove docker network rm "${REL_NETWORK}"
}

rel_assert_artifacts_redacted() {
    python3 - "${PGS3_RUN_DIR}" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1])
values = {
    os.environ.get("PGS3_TEST_ACCESS_KEY_A", "").encode(),
    os.environ.get("PGS3_TEST_SECRET_A", "").encode(),
}
values.discard(b"")
leaks: list[str] = []
files = 0
for path in root.rglob("*"):
    if not path.is_file() or path.is_symlink():
        continue
    files += 1
    data = path.read_bytes()
    if any(value in data for value in values):
        leaks.append(str(path.relative_to(root)))
if leaks:
    print("unredacted test credential material found in: " + ", ".join(sorted(leaks)))
    raise SystemExit(1)
print(f"redaction audit passed for {files} evidence files")
PY
}

rel_cleanup() {
    local original_status=$?
    local index cleanup_rc
    trap - EXIT INT TERM
    set +e

    for index in "${REL_HOST_PIDS[@]}"; do
        if kill -0 "${index}" >/dev/null 2>&1; then
            kill "${index}" >/dev/null 2>&1 || true
        fi
        wait "${index}" >/dev/null 2>&1 || true
    done

    for ((index=${#REL_CONTAINERS[@]} - 1; index >= 0; index--)); do
        rel_safe_remove_container "${REL_CONTAINERS[index]}"
        cleanup_rc=$?
        if ((cleanup_rc != 0)); then
            REL_CLEANUP_FAILED=1
        fi
    done
    for ((index=${#REL_VOLUMES[@]} - 1; index >= 0; index--)); do
        rel_safe_remove_volume "${REL_VOLUMES[index]}"
        cleanup_rc=$?
        if ((cleanup_rc != 0)); then
            REL_CLEANUP_FAILED=1
        fi
    done
    rel_safe_remove_network
    cleanup_rc=$?
    if ((cleanup_rc != 0)); then
        REL_CLEANUP_FAILED=1
    fi

    if [[ -n ${REL_TMP_DIR} && -d ${REL_TMP_DIR} ]]; then
        case ${REL_TMP_DIR} in
            "${TMPDIR:-/tmp}"/pgs3-reliability.*) rm -rf -- "${REL_TMP_DIR}" ;;
            *)
                printf 'refusing to remove unexpected temporary directory: %s\n' "${REL_TMP_DIR}" >&2
                REL_CLEANUP_FAILED=1
                ;;
        esac
    fi

    evidence_try final-redaction-audit rel_assert_artifacts_redacted
    if ((PGS3_EVIDENCE_LAST_RC != 0)); then
        REL_CLEANUP_FAILED=1
        REL_RESULT=FAIL
        original_status=1
    fi

    if [[ ${REL_RESULT} == RUNNING ]]; then
        REL_RESULT=FAIL
    fi
    if ((original_status != 0)) && [[ ${REL_RESULT} == PASS ]]; then
        REL_RESULT=FAIL
    fi
    if ((REL_CLEANUP_FAILED)) && [[ ${REL_RESULT} == PASS ]]; then
        REL_RESULT=FAIL
        original_status=1
    fi
    evidence_finalize "${REL_RESULT}" || original_status=1
    evidence_cleanup
    printf 'reliability result: %s\nmanifest: %s/manifest.json\n' \
        "${REL_RESULT}" "${PGS3_RUN_DIR}"
    exit "${original_status}"
}
