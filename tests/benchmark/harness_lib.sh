#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034 # state is consumed by run.sh and the EXIT trap

benchmark_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${benchmark_dir}/../.." && pwd)
# shellcheck disable=SC1091 # repository-local evidence helper
source "${repo_dir}/scripts/lib/evidence.sh"

export PGS3_BENCH_ACCESS_KEY=${PGS3_BENCH_ACCESS_KEY:-PGS3BENCHACCESS01}
if [[ -z ${PGS3_BENCH_SECRET:-} ]]; then
    PGS3_BENCH_SECRET=$(python3 -c 'import secrets; print(secrets.token_hex(32))')
    export PGS3_BENCH_SECRET
fi
export MINIO_ROOT_USER=${PGS3_BENCH_ACCESS_KEY}
export MINIO_ROOT_PASSWORD=${PGS3_BENCH_SECRET}
export PGS3_REDACT_ENV_NAMES="${PGS3_REDACT_ENV_NAMES:+${PGS3_REDACT_ENV_NAMES},}PGS3_BENCH_ACCESS_KEY,PGS3_BENCH_SECRET,MINIO_ROOT_USER,MINIO_ROOT_PASSWORD"

BENCH_RESULT=RUNNING
BENCH_CLEANUP_FAILED=0
BENCH_RUN_TAG=''
BENCH_NETWORK=''
BENCH_PGS3_CONTAINER=''
BENCH_MINIO_CONTAINER=''
BENCH_PGS3_VOLUME=''
BENCH_MINIO_VOLUME=''
BENCH_PGS3_IMAGE=''
BENCH_MINIO_IMAGE=''
BENCH_CLIENT_IMAGE=''
BENCH_PROFILE=''
BENCH_PG_MAJOR=''
BENCH_WORKERS=''
BENCH_SHARED_BUFFERS=''
BENCH_RESULTS_DIR=''
BENCH_SMOKE_SIZES=''
BENCH_SMOKE_SAMPLES=''
BENCH_SMOKE_WARMUPS=''
BENCH_SMOKE_CONCURRENCY=''
BENCH_ENVIRONMENT_NOTE=''

bench_require_command() {
    local name=$1
    if ! command -v "${name}" >/dev/null 2>&1; then
        printf 'required command is unavailable: %s\n' "${name}" >&2
        return 127
    fi
}

bench_init_runtime() {
    BENCH_RUN_TAG=$(PGS3_BENCH_TAG_SOURCE="${PGS3_RUN_DIR}" python3 - <<'PY'
import hashlib
import os

print(hashlib.sha256(os.environ["PGS3_BENCH_TAG_SOURCE"].encode()).hexdigest()[:12])
PY
)
    BENCH_NETWORK="pgs3-bench-net-${BENCH_RUN_TAG}"
    BENCH_PGS3_CONTAINER="pgs3-bench-pg-${BENCH_RUN_TAG}"
    BENCH_MINIO_CONTAINER="pgs3-bench-minio-${BENCH_RUN_TAG}"
    BENCH_PGS3_VOLUME="pgs3-bench-pgdata-${BENCH_RUN_TAG}"
    BENCH_MINIO_VOLUME="pgs3-bench-minio-data-${BENCH_RUN_TAG}"
    BENCH_RESULTS_DIR="${PGS3_RUN_DIR}/benchmark"
    mkdir -p -- "${BENCH_RESULTS_DIR}"

    evidence_run benchmark-network-create docker network create \
        --label "pgs3.benchmark.run=${BENCH_RUN_TAG}" \
        "${BENCH_NETWORK}"
    evidence_run benchmark-pgs3-volume-create docker volume create \
        --label "pgs3.benchmark.run=${BENCH_RUN_TAG}" \
        "${BENCH_PGS3_VOLUME}"
    evidence_run benchmark-minio-volume-create docker volume create \
        --label "pgs3.benchmark.run=${BENCH_RUN_TAG}" \
        "${BENCH_MINIO_VOLUME}"
}

bench_start_pgs3() {
    evidence_run benchmark-pgs3-start docker run --detach \
        --pull never \
        --name "${BENCH_PGS3_CONTAINER}" \
        --label "pgs3.benchmark.run=${BENCH_RUN_TAG}" \
        --network "${BENCH_NETWORK}" \
        --network-alias pgs3-benchmark \
        --volume "${BENCH_PGS3_VOLUME}:/var/lib/postgresql/data" \
        --restart no \
        --env POSTGRES_HOST_AUTH_METHOD=trust \
        --env POSTGRES_INITDB_ARGS=--data-checksums \
        --shm-size 3g \
        "${BENCH_PGS3_IMAGE}" \
        postgres \
        -c shared_preload_libraries=pgs3 \
        -c max_worker_processes=48 \
        -c shared_buffers="${BENCH_SHARED_BUFFERS}" \
        -c fsync=on \
        -c full_page_writes=on \
        -c synchronous_commit=on \
        -c max_wal_size=4GB \
        -c checkpoint_timeout=30min \
        -c jit=off \
        -c pgs3.enabled=off \
        -c pgs3.listen_addr=0.0.0.0 \
        -c pgs3.port=9000 \
        -c "pgs3.workers=${BENCH_WORKERS}" \
        -c pgs3.statement_timeout_ms=180000 \
        -c log_min_messages=info \
        -c 'log_line_prefix=%m [%p] %q%u@%d '
}

bench_start_minio() {
    evidence_run benchmark-minio-start docker run --detach \
        --pull never \
        --name "${BENCH_MINIO_CONTAINER}" \
        --label "pgs3.benchmark.run=${BENCH_RUN_TAG}" \
        --network "${BENCH_NETWORK}" \
        --network-alias minio-benchmark \
        --volume "${BENCH_MINIO_VOLUME}:/data" \
        --restart no \
        --env MINIO_ROOT_USER \
        --env MINIO_ROOT_PASSWORD \
        "${BENCH_MINIO_IMAGE}" \
        server /data --address :9000 --console-address :9001
}

bench_wait_postgres() {
    local attempt
    for attempt in $(seq 1 120); do
        if docker exec "${BENCH_PGS3_CONTAINER}" pg_isready \
            --username postgres --dbname postgres >/dev/null 2>&1; then
            docker exec "${BENCH_PGS3_CONTAINER}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --tuples-only --no-align --command \
                "SELECT current_setting('server_version'), pg_postmaster_start_time()"
            return 0
        fi
        sleep 1
    done
    printf 'PostgreSQL did not become ready in 120 seconds\n' >&2
    return 1
}

bench_install_pgs3() {
    docker exec --interactive \
        --env PGS3_BENCH_ACCESS_KEY \
        --env PGS3_BENCH_SECRET \
        "${BENCH_PGS3_CONTAINER}" \
        bash -Eeuo pipefail -c '
            psql --username postgres --dbname postgres --no-psqlrc \
                --set ON_ERROR_STOP=1 \
                --set access_key="$PGS3_BENCH_ACCESS_KEY" \
                --set secret="$PGS3_BENCH_SECRET"
        ' <<'SQL'
CREATE EXTENSION pgs3;
CREATE ROLE pgs3_bench_tenant
    NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SELECT pgs3.create_credential(
    :'access_key', :'secret', 'pgs3_bench_tenant'::name, true
);
SELECT pgs3.start();
SQL
}

bench_wait_workers() {
    local ready attempt
    for attempt in $(seq 1 90); do
        ready=$(docker exec "${BENCH_PGS3_CONTAINER}" psql \
            --username postgres --dbname postgres --no-psqlrc \
            --tuples-only --no-align --command \
            "SELECT count(*) FROM pgs3.worker_state
              WHERE worker_kind = 'http' AND desired AND status = 'running'" \
            2>/dev/null | tr -d '[:space:]')
        if [[ ${ready:-0} == "${BENCH_WORKERS}" ]]; then
            docker exec "${BENCH_PGS3_CONTAINER}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --command 'TABLE pgs3.worker_state'
            return 0
        fi
        sleep 1
    done
    printf 'pgs3 worker pool did not converge: expected=%s actual=%s\n' \
        "${BENCH_WORKERS}" "${ready:-0}" >&2
    return 1
}

bench_wait_endpoint() {
    local host=$1 port=$2
    docker run --rm --pull never \
        --network "${BENCH_NETWORK}" \
        --env "PGS3_WAIT_HOST=${host}" \
        --env "PGS3_WAIT_PORT=${port}" \
        "${BENCH_CLIENT_IMAGE}" \
        python -c '
import os, socket, time
host=os.environ["PGS3_WAIT_HOST"]
port=int(os.environ["PGS3_WAIT_PORT"])
deadline=time.monotonic()+30
last=None
while time.monotonic()<deadline:
    try:
        with socket.create_connection((host,port),timeout=1):
            print(f"ready={host}:{port}")
            raise SystemExit(0)
    except OSError as error:
        last=error
        time.sleep(0.25)
raise SystemExit(f"endpoint not ready: {host}:{port}: {last}")
'
}

bench_wait_minio_health() {
    docker run --rm --pull never \
        --network "${BENCH_NETWORK}" \
        "${BENCH_CLIENT_IMAGE}" \
        python -c '
import time, urllib.request
url="http://minio-benchmark:9000/minio/health/ready"
deadline=time.monotonic()+30
last=None
while time.monotonic()<deadline:
    try:
        with urllib.request.urlopen(url,timeout=1) as response:
            if response.status==200:
                print("minio_health=ready")
                raise SystemExit(0)
    except Exception as error:
        last=error
        time.sleep(0.25)
raise SystemExit(f"MinIO health did not become ready: {last}")
'
}

bench_capture_environment() {
    python3 "${benchmark_dir}/environment.py" \
        --output "${BENCH_RESULTS_DIR}/environment.json" \
        --profile "${BENCH_PROFILE}" \
        --pg-major "${BENCH_PG_MAJOR}" \
        --pgs3-image "${BENCH_PGS3_IMAGE}" \
        --minio-image "${BENCH_MINIO_IMAGE}" \
        --client-image "${BENCH_CLIENT_IMAGE}" \
        --pgs3-container "${BENCH_PGS3_CONTAINER}" \
        --minio-container "${BENCH_MINIO_CONTAINER}" \
        --pgs3-volume "${BENCH_PGS3_VOLUME}" \
        --minio-volume "${BENCH_MINIO_VOLUME}" \
        --workers "${BENCH_WORKERS}" \
        --shared-buffers "${BENCH_SHARED_BUFFERS}" \
        --environment-note "${BENCH_ENVIRONMENT_NOTE}"
}

bench_execute() {
    local -a arguments=(
        run
        --profile "${BENCH_PROFILE}"
        --pgs3-endpoint http://pgs3-benchmark:9000
        --minio-endpoint http://minio-benchmark:9000
        --run-tag "${BENCH_RUN_TAG}"
        --output-dir /evidence
        --environment /evidence/environment.json
        --timeout 180
    )
    if [[ ${BENCH_PROFILE} == smoke ]]; then
        arguments+=(
            --smoke-sizes "${BENCH_SMOKE_SIZES}"
            --smoke-samples "${BENCH_SMOKE_SAMPLES}"
            --smoke-warmups "${BENCH_SMOKE_WARMUPS}"
            --smoke-concurrency "${BENCH_SMOKE_CONCURRENCY}"
        )
    fi
    docker run --rm --pull never \
        --network "${BENCH_NETWORK}" \
        --mount "type=bind,src=${repo_dir},dst=/repo,readonly" \
        --mount "type=bind,src=${BENCH_RESULTS_DIR},dst=/evidence" \
        --env PGS3_BENCH_ACCESS_KEY \
        --env PGS3_BENCH_SECRET \
        "${BENCH_CLIENT_IMAGE}" \
        python /repo/tests/benchmark/benchmark.py "${arguments[@]}"
}

bench_collect_pgs3_runtime() {
    docker exec "${BENCH_PGS3_CONTAINER}" psql \
        --username postgres --dbname postgres --no-psqlrc --command '
            TABLE pgs3.stats;
            SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size;
            SELECT relname, pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
              FROM pg_class AS c
              JOIN pg_namespace AS n ON n.oid = c.relnamespace
             WHERE n.nspname = '\''pgs3'\'' AND c.relkind IN ('\''r'\'', '\''p'\'')
             ORDER BY pg_total_relation_size(c.oid) DESC, relname;
        '
}

bench_wait_pgs3_metrics() {
    local ready attempt
    for attempt in $(seq 1 40); do
        ready=$(docker exec "${BENCH_PGS3_CONTAINER}" psql \
            --username postgres --dbname postgres --no-psqlrc \
            --tuples-only --no-align --command '
                SELECT CASE WHEN
                    COALESCE(sum(requests), 0) > 0
                    AND COALESCE(bool_and(in_flight = 0), false)
                THEN 1 ELSE 0 END
                  FROM pgs3.worker_metric
                 WHERE worker_kind = '\''http'\''
            ' 2>/dev/null | tr -d '[:space:]')
        if [[ ${ready:-0} == 1 ]]; then
            bench_collect_pgs3_runtime
            return 0
        fi
        sleep 0.25
    done
    bench_collect_pgs3_runtime || true
    printf 'pgs3 metrics did not flush balanced request counters within 10 seconds\n' >&2
    return 1
}

bench_print_summary() {
    local summary="${BENCH_RESULTS_DIR}/summary.json"
    if [[ ! -f ${summary} ]]; then
        printf 'benchmark summary was not produced\n' >&2
        return 1
    fi
    python3 -m json.tool "${summary}"
}

bench_safe_remove_container() {
    local container=$1 label
    if [[ -z ${container} ]] || ! docker container inspect "${container}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker container inspect "${container}" \
        --format '{{ index .Config.Labels "pgs3.benchmark.run" }}')
    if [[ -z ${BENCH_RUN_TAG} || ${label} != "${BENCH_RUN_TAG}" ]]; then
        printf 'refusing to remove container with unexpected benchmark label: %s label=%s\n' \
            "${container}" "${label}" >&2
        return 1
    fi
    docker rm --force --volumes "${container}"
}

bench_safe_remove_volume() {
    local volume=$1 label
    if [[ -z ${volume} ]] || ! docker volume inspect "${volume}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker volume inspect "${volume}" \
        --format '{{ index .Labels "pgs3.benchmark.run" }}')
    if [[ -z ${BENCH_RUN_TAG} || ${label} != "${BENCH_RUN_TAG}" ]]; then
        printf 'refusing to remove volume with unexpected benchmark label: %s label=%s\n' \
            "${volume}" "${label}" >&2
        return 1
    fi
    docker volume rm "${volume}"
}

bench_safe_remove_network() {
    local label
    if [[ -z ${BENCH_NETWORK} ]] || ! docker network inspect "${BENCH_NETWORK}" >/dev/null 2>&1; then
        return 0
    fi
    label=$(docker network inspect "${BENCH_NETWORK}" \
        --format '{{ index .Labels "pgs3.benchmark.run" }}')
    if [[ -z ${BENCH_RUN_TAG} || ${label} != "${BENCH_RUN_TAG}" ]]; then
        printf 'refusing to remove network with unexpected benchmark label: %s label=%s\n' \
            "${BENCH_NETWORK}" "${label}" >&2
        return 1
    fi
    docker network rm "${BENCH_NETWORK}"
}

bench_assert_artifacts_redacted() {
    PGS3_BENCH_AUDIT_DIR=${PGS3_RUN_DIR} python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["PGS3_BENCH_AUDIT_DIR"])
needles = {
    os.environ.get("PGS3_BENCH_ACCESS_KEY", "").encode(),
    os.environ.get("PGS3_BENCH_SECRET", "").encode(),
}
needles.discard(b"")
leaks = []
files = 0
for path in sorted(root.rglob("*")):
    if not path.is_file():
        continue
    files += 1
    data = path.read_bytes()
    if any(needle in data for needle in needles):
        leaks.append(str(path.relative_to(root)))
if leaks:
    raise SystemExit("unredacted benchmark credential material: " + ", ".join(leaks))
print(f"benchmark redaction audit passed for {files} evidence files")
PY
}

bench_cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    set +e

    if [[ -n ${BENCH_RESULTS_DIR} && -f ${BENCH_RESULTS_DIR}/summary.json ]]; then
        evidence_try benchmark-summary bench_print_summary
        ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    fi
    if [[ -n ${BENCH_PGS3_CONTAINER} ]] \
        && docker container inspect "${BENCH_PGS3_CONTAINER}" >/dev/null 2>&1; then
        evidence_try benchmark-final-pgs3-runtime bench_collect_pgs3_runtime
        ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
        evidence_try benchmark-pgs3-logs docker logs "${BENCH_PGS3_CONTAINER}"
        ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    fi
    if [[ -n ${BENCH_MINIO_CONTAINER} ]] \
        && docker container inspect "${BENCH_MINIO_CONTAINER}" >/dev/null 2>&1; then
        evidence_try benchmark-minio-logs docker logs "${BENCH_MINIO_CONTAINER}"
        ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    fi

    evidence_try benchmark-pgs3-remove bench_safe_remove_container "${BENCH_PGS3_CONTAINER}"
    ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    evidence_try benchmark-minio-remove bench_safe_remove_container "${BENCH_MINIO_CONTAINER}"
    ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    evidence_try benchmark-pgs3-volume-remove bench_safe_remove_volume "${BENCH_PGS3_VOLUME}"
    ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    evidence_try benchmark-minio-volume-remove bench_safe_remove_volume "${BENCH_MINIO_VOLUME}"
    ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    evidence_try benchmark-network-remove bench_safe_remove_network
    ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1
    evidence_try benchmark-final-redaction-audit bench_assert_artifacts_redacted
    ((PGS3_EVIDENCE_LAST_RC == 0)) || BENCH_CLEANUP_FAILED=1

    if [[ ${BENCH_RESULT} == RUNNING ]]; then
        BENCH_RESULT=FAIL
    fi
    if ((original_status != 0)) && [[ ${BENCH_RESULT} == PASS ]]; then
        BENCH_RESULT=FAIL
    fi
    if ((BENCH_CLEANUP_FAILED)) && [[ ${BENCH_RESULT} == PASS ]]; then
        BENCH_RESULT=FAIL
        original_status=1
    fi
    if [[ ${BENCH_RESULT} == FAIL ]] && ((original_status == 0)); then
        original_status=1
    fi
    evidence_finalize "${BENCH_RESULT}" || original_status=1
    evidence_cleanup
    printf 'benchmark harness result: %s\nmanifest: %s/manifest.json\n' \
        "${BENCH_RESULT}" "${PGS3_RUN_DIR}"
    exit "${original_status}"
}
