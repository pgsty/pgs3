#!/usr/bin/env bash
# shellcheck shell=bash

integration_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${integration_dir}/../.." && pwd)
# shellcheck disable=SC1091 # resolved from this file, not the caller's cwd
source "${repo_dir}/scripts/lib/evidence.sh"

export PGS3_ACCESS_KEY_A=PGS3AACCESSKEY0001
export PGS3_SECRET_A=pgs3-fixed-acceptance-secret-a-2026
export PGS3_ACCESS_KEY_B=PGS3BACCESSKEY0002
export PGS3_SECRET_B=pgs3-fixed-acceptance-secret-b-2026
export PGS3_REDACT_ENV_NAMES=PGS3_ACCESS_KEY_A,PGS3_ACCESS_KEY_B,PGS3_SECRET_A,PGS3_SECRET_B,RCLONE_CONFIG_PGS3_ACCESS_KEY_ID,RCLONE_CONFIG_PGS3_SECRET_ACCESS_KEY

harness_container=''
harness_network=''
harness_work_dir=''
harness_result=RUNNING
harness_cleanup_failed=0
harness_image=''
harness_client_image=${PGS3_CLIENT_IMAGE:-pgs3-client-test:20250226}
harness_host_port=''
harness_alias=''
harness_postmaster_started=''
export harness_fuse_mode=''
harness_allow_privileged_fuse=${PGS3_ALLOW_PRIVILEGED_FUSE:-0}

harness_require_command() {
    local command=$1
    if ! command -v "${command}" >/dev/null 2>&1; then
        printf 'required command is unavailable: %s\n' "${command}" >&2
        return 127
    fi
}

harness_pick_port() {
    python3 - <<'PY'
import socket
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    print(listener.getsockname()[1])
PY
}

harness_wait_postgres() {
    printf '+ wait for PostgreSQL readiness in %s\n' "${harness_container}"
    for _ in $(seq 1 120); do
        if docker exec "${harness_container}" pg_isready \
            --username postgres --dbname postgres >/dev/null 2>&1; then
            docker exec "${harness_container}" psql --username postgres --dbname postgres \
                --no-psqlrc --tuples-only --no-align --command \
                'SELECT current_setting('\''server_version'\''), pg_postmaster_start_time()'
            return 0
        fi
        sleep 1
    done
    printf 'PostgreSQL did not become ready in 120 seconds\n' >&2
    return 1
}

harness_install_extension() {
    printf '+ CREATE EXTENSION, two restricted roles, two temporary credentials\n'
    docker exec --interactive \
        --env PGS3_ACCESS_KEY_A \
        --env PGS3_SECRET_A \
        --env PGS3_ACCESS_KEY_B \
        --env PGS3_SECRET_B \
        "${harness_container}" \
        bash -Eeuo pipefail -c '
            psql --username postgres --dbname postgres --no-psqlrc \
                --set ON_ERROR_STOP=1 \
                --set access_a="$PGS3_ACCESS_KEY_A" \
                --set secret_a="$PGS3_SECRET_A" \
                --set access_b="$PGS3_ACCESS_KEY_B" \
                --set secret_b="$PGS3_SECRET_B"
        ' <<'SQL'
CREATE EXTENSION pgs3;
CREATE ROLE pgs3_tenant_a NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
CREATE ROLE pgs3_tenant_b NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SELECT pgs3.create_credential(:'access_a', :'secret_a', 'pgs3_tenant_a'::name, true);
SELECT pgs3.create_credential(:'access_b', :'secret_b', 'pgs3_tenant_b'::name, true);
SELECT pgs3.start();
SQL
}

harness_wait_workers() {
    local ready
    printf '+ wait for two HTTP workers and one GC worker\n'
    for _ in $(seq 1 60); do
        ready=$(docker exec "${harness_container}" psql \
            --username postgres --dbname postgres --no-psqlrc --tuples-only --no-align \
            --command "SELECT count(*) FROM pgs3.worker_state WHERE desired AND status = 'running' AND worker_kind = 'http'" \
            2>/dev/null | tr -d '[:space:]')
        if [[ ${ready:-0} -ge 2 ]]; then
            docker exec "${harness_container}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --command 'TABLE pgs3.stats'
            return 0
        fi
        sleep 1
    done
    docker exec "${harness_container}" psql --username postgres --dbname postgres \
        --no-psqlrc --command 'TABLE pgs3.worker_state' || true
    printf 'HTTP worker pool did not converge in 60 seconds\n' >&2
    return 1
}

harness_wait_http_port() {
    printf '+ wait for TCP endpoint 127.0.0.1:%s\n' "${harness_host_port}"
    PGS3_WAIT_PORT=${harness_host_port} python3 - <<'PY'
import os
import socket
import time

port = int(os.environ["PGS3_WAIT_PORT"])
deadline = time.monotonic() + 30
last = None
while time.monotonic() < deadline:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            print(f"TCP endpoint ready on 127.0.0.1:{port}")
            raise SystemExit(0)
    except OSError as error:
        last = error
        time.sleep(0.25)
raise SystemExit(f"TCP endpoint was not ready: {last}")
PY
}

harness_capture_postmaster_identity() {
    harness_postmaster_started=$(docker exec "${harness_container}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --tuples-only --no-align \
        --command "SELECT pg_postmaster_start_time()::text" | tr -d '\r\n')
    test -n "${harness_postmaster_started}"
    printf 'postmaster_started=%s\n' "${harness_postmaster_started}"
}

harness_assert_postmaster_identity() {
    local actual
    actual=$(docker exec "${harness_container}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --tuples-only --no-align \
        --command "SELECT pg_postmaster_start_time()::text" | tr -d '\r\n')
    printf 'postmaster_started_before=%s after=%s\n' \
        "${harness_postmaster_started}" "${actual}"
    [[ -n ${harness_postmaster_started} && ${actual} == "${harness_postmaster_started}" ]]
}

harness_control_pool() {
    local action=$1 actual
    case ${action} in
        start|stop) ;;
        *) printf 'invalid pool action: %s\n' "${action}" >&2; return 2 ;;
    esac
    actual=$(docker exec "${harness_container}" psql \
        --username postgres --dbname postgres --no-psqlrc \
        --tuples-only --no-align \
        --command "SELECT pgs3.${action}()" | tr -d '[:space:]')
    printf 'pgs3.%s()=%s\n' "${action}" "${actual}"
    [[ ${actual} == t ]]
}

harness_wait_workers_stopped() {
    local stopped
    for _ in $(seq 1 60); do
        stopped=$(docker exec "${harness_container}" psql \
            --username postgres --dbname postgres --no-psqlrc \
            --tuples-only --no-align --command "
                SELECT CASE WHEN
                    NOT EXISTS (
                        SELECT 1 FROM pg_catalog.pg_stat_activity
                         WHERE datname = current_database()
                           AND backend_type IN ('pgs3 launcher', 'pgs3 http', 'pgs3 gc')
                    )
                    AND NOT EXISTS (
                        SELECT 1 FROM pgs3.worker_state
                         WHERE desired OR status NOT IN ('stopped', 'error')
                    )
                THEN 1 ELSE 0 END
            " 2>/dev/null | tr -d '[:space:]')
        if [[ ${stopped:-0} == 1 ]]; then
            docker exec "${harness_container}" psql \
                --username postgres --dbname postgres --no-psqlrc \
                --command 'TABLE pgs3.worker_state'
            return 0
        fi
        sleep 0.25
    done
    printf 'dynamic worker pool did not stop in 15 seconds\n' >&2
    return 1
}

harness_wait_http_port_closed() {
    local port_hex status consecutive_absences=0
    printf -v port_hex '%04X' 9000
    for _ in $(seq 1 50); do
        if docker exec "${harness_container}" awk -v wanted="${port_hex}" '
            $4 == "0A" {
                split($2, endpoint, ":")
                if (toupper(endpoint[2]) == wanted) {
                    found = 1
                }
            }
            END { exit found ? 0 : 3 }
        ' /proc/net/tcp /proc/net/tcp6 >/dev/null; then
            consecutive_absences=0
        else
            status=$?
            if ((status != 3)); then
                printf 'failed to inspect container listeners: exit_status=%s\n' \
                    "${status}" >&2
                return "${status}"
            fi
            consecutive_absences=$((consecutive_absences + 1))
            if ((consecutive_absences >= 5)); then
                printf 'container listener is absent: container=%s port=9000\n' \
                    "${harness_container}"
                return 0
            fi
        fi
        sleep 0.1
    done
    printf 'container listener remained present: container=%s port=9000\n' \
        "${harness_container}" >&2
    docker exec "${harness_container}" cat /proc/net/tcp /proc/net/tcp6 >&2
    return 1
}

harness_start_server() {
    local pg_major=$1 skip_build=$2
    harness_image="${PGS3_IMAGE_PREFIX:-pgs3-test}:pg${pg_major}"
    if ((skip_build)); then
        evidence_run server-image-inspect docker image inspect "${harness_image}" \
            --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
    else
        evidence_run server-image-build "${repo_dir}/scripts/build-images.sh" "${pg_major}"
    fi

    harness_host_port=$(harness_pick_port)
    local identity
    identity=$(printf '%s' "${PGS3_RUN_DIR}" | sha256sum | cut -c1-12)
    harness_container="pgs3-accept-${identity}"
    harness_network="pgs3-accept-${identity}"
    harness_alias="pgs3-under-test-${identity}"
    harness_work_dir=$(mktemp -d "${TMPDIR:-/tmp}/pgs3-clients.XXXXXXXX")

    evidence_run network-create docker network create "${harness_network}"
    evidence_run postgres-start docker run --detach \
        --name "${harness_container}" \
        --network "${harness_network}" \
        --network-alias "${harness_alias}" \
        --publish "127.0.0.1:${harness_host_port}:9000" \
        --env POSTGRES_HOST_AUTH_METHOD=trust \
        "${harness_image}" \
        postgres \
        -c shared_preload_libraries=pgs3 \
        -c max_worker_processes=20 \
        -c pgs3.enabled=off \
        -c pgs3.listen_addr=0.0.0.0 \
        -c pgs3.port=9000 \
        -c pgs3.workers=2 \
        -c log_min_messages=info
    evidence_run postgres-ready harness_wait_postgres
    evidence_run extension-install harness_install_extension
    evidence_run worker-ready harness_wait_workers
    evidence_run http-port-ready harness_wait_http_port
}

harness_probe() {
    local phase=${1:-initial} suffix
    suffix=$(printf '%s' "${PGS3_RUN_DIR}" | sha256sum | cut -c1-12)
    suffix="${suffix}-${phase}"
    evidence_run "stdlib-sigv4-probe-${phase}" python3 "${integration_dir}/sigv4_probe.py" \
        --endpoint "http://127.0.0.1:${harness_host_port}" \
        --suffix "${suffix}"
}

harness_dynamic_lifecycle() {
    evidence_run dynamic-postmaster-baseline harness_capture_postmaster_identity
    evidence_run dynamic-stop-cross-session harness_control_pool stop
    evidence_run dynamic-workers-stopped harness_wait_workers_stopped
    evidence_run dynamic-http-port-closed harness_wait_http_port_closed
    evidence_run dynamic-stop-idempotent harness_control_pool stop
    evidence_run dynamic-restart-cross-session harness_control_pool start
    evidence_run dynamic-restart-workers harness_wait_workers
    evidence_run dynamic-restart-http-port harness_wait_http_port
    evidence_run dynamic-postmaster-unchanged harness_assert_postmaster_identity
    harness_probe restarted
}

harness_wait_metrics() {
    local ready
    printf '+ wait for HTTP metrics flush and balanced in-flight gauges\n'
    for _ in $(seq 1 40); do
        ready=$(docker exec "${harness_container}" psql \
            --username postgres --dbname postgres --no-psqlrc --tuples-only --no-align \
            --command "
                WITH h AS (
                    SELECT *
                      FROM pgs3.worker_metric
                     WHERE worker_kind = 'http'
                )
                SELECT CASE WHEN
                    COALESCE(sum(requests), 0) > 0
                    AND COALESCE(sum(errors), 0) > 0
                    AND COALESCE(sum(bytes_in), 0) > 0
                    AND COALESCE(sum(bytes_out), 0) > 0
                    AND COALESCE(sum(latency_us), 0) > 0
                    AND COALESCE(bool_and(in_flight = 0), false)
                    AND COALESCE(sum(requests) FILTER (
                        WHERE operation = 'CreateBucket'
                    ), 0) >= 2
                    AND COALESCE(sum(latency_le_1ms), 0)
                        <= COALESCE(sum(latency_le_5ms), 0)
                    AND COALESCE(sum(latency_le_5ms), 0)
                        <= COALESCE(sum(latency_le_10ms), 0)
                    AND COALESCE(sum(latency_le_10ms), 0)
                        <= COALESCE(sum(latency_le_50ms), 0)
                    AND COALESCE(sum(latency_le_50ms), 0)
                        <= COALESCE(sum(latency_le_100ms), 0)
                    AND COALESCE(sum(latency_le_100ms), 0)
                        <= COALESCE(sum(latency_le_500ms), 0)
                    AND COALESCE(sum(latency_le_500ms), 0)
                        <= COALESCE(sum(latency_le_1s), 0)
                    AND COALESCE(sum(latency_le_1s), 0)
                        <= COALESCE(sum(requests), 0)
                THEN 1 ELSE 0 END
                  FROM h
            " 2>/dev/null | tr -d '[:space:]')
        if [[ ${ready:-0} == 1 ]]; then
            harness_collect_runtime
            return 0
        fi
        sleep 0.25
    done
    harness_collect_runtime || true
    printf 'HTTP metrics did not flush nonzero balanced counters within 10 seconds\n' >&2
    return 1
}

harness_build_client_image() {
    evidence_run client-image-build "${repo_dir}/scripts/build-client-image.sh"
}

harness_client_environment() {
    export AWS_ACCESS_KEY_ID=${PGS3_ACCESS_KEY_A}
    export AWS_SECRET_ACCESS_KEY=${PGS3_SECRET_A}
    export AWS_DEFAULT_REGION=us-east-1
    export AWS_REGION=us-east-1
    export AWS_EC2_METADATA_DISABLED=true
    export RCLONE_CONFIG_PGS3_TYPE=s3
    export RCLONE_CONFIG_PGS3_PROVIDER=Other
    export RCLONE_CONFIG_PGS3_ENV_AUTH=false
    export RCLONE_CONFIG_PGS3_ACCESS_KEY_ID=${PGS3_ACCESS_KEY_A}
    export RCLONE_CONFIG_PGS3_SECRET_ACCESS_KEY=${PGS3_SECRET_A}
    export RCLONE_CONFIG_PGS3_REGION=us-east-1
    export RCLONE_CONFIG_PGS3_ENDPOINT="http://${harness_alias}:9000"
    export RCLONE_CONFIG_PGS3_FORCE_PATH_STYLE=true
    export RCLONE_CONFIG_PGS3_NO_CHECK_BUCKET=true
}

harness_run_client_case() {
    local case_name=$1 bucket=$2
    shift 2
    docker run --rm \
        --network "${harness_network}" \
        --mount "type=bind,src=${repo_dir},dst=/repo,readonly" \
        --mount "type=bind,src=${harness_work_dir},dst=/work" \
        --env AWS_ACCESS_KEY_ID \
        --env AWS_SECRET_ACCESS_KEY \
        --env AWS_DEFAULT_REGION \
        --env AWS_REGION \
        --env AWS_EC2_METADATA_DISABLED \
        --env RCLONE_CONFIG_PGS3_TYPE \
        --env RCLONE_CONFIG_PGS3_PROVIDER \
        --env RCLONE_CONFIG_PGS3_ENV_AUTH \
        --env RCLONE_CONFIG_PGS3_ACCESS_KEY_ID \
        --env RCLONE_CONFIG_PGS3_SECRET_ACCESS_KEY \
        --env RCLONE_CONFIG_PGS3_REGION \
        --env RCLONE_CONFIG_PGS3_ENDPOINT \
        --env RCLONE_CONFIG_PGS3_FORCE_PATH_STYLE \
        --env RCLONE_CONFIG_PGS3_NO_CHECK_BUCKET \
        --env "PGS3_ENDPOINT=http://${harness_alias}:9000" \
        --env "PGS3_TEST_BUCKET=${bucket}" \
        "$@" \
        "${harness_client_image}" \
        bash /repo/tests/integration/client_cases.sh "${case_name}"
}

harness_fuse_preflight() {
    case ${harness_allow_privileged_fuse} in
        0|1) ;;
        *)
            printf 'PGS3_ALLOW_PRIVILEGED_FUSE must be 0 or 1\n' >&2
            return 2
            ;;
    esac
    if [[ -c /dev/fuse ]]; then
        harness_fuse_mode=device
        docker run --rm \
            --device /dev/fuse \
            --cap-add SYS_ADMIN \
            --security-opt apparmor=unconfined \
            "${harness_client_image}" \
            bash -Eeuo pipefail -c \
                'test -c /dev/fuse && test -r /dev/fuse && test -w /dev/fuse'
        return
    fi
    if ((harness_allow_privileged_fuse == 0)); then
        printf '%s\n' \
            '/dev/fuse is unavailable on the Docker host; set PGS3_ALLOW_PRIVILEGED_FUSE=1 to probe the explicit Docker Desktop/LinuxKit fallback' >&2
        return 125
    fi
    harness_fuse_mode=privileged
    docker run --rm \
        --privileged \
        "${harness_client_image}" \
        bash -Eeuo pipefail -c '
            [[ -e /dev/fuse ]] || mknod -m 666 /dev/fuse c 10 229
            test -c /dev/fuse && test -r /dev/fuse && test -w /dev/fuse
            python - <<"PY"
import os
fd = os.open("/dev/fuse", os.O_RDWR)
os.close(fd)
PY
        '
}

harness_collect_runtime() {
    docker exec "${harness_container}" psql --username postgres --dbname postgres \
        --no-psqlrc --command 'TABLE pgs3.stats'
}

harness_cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    set +e

    if [[ -n ${harness_container} ]] && docker container inspect "${harness_container}" >/dev/null 2>&1; then
        evidence_try final-runtime-stats harness_collect_runtime
        ((PGS3_EVIDENCE_LAST_RC == 0)) || harness_cleanup_failed=1
        evidence_try postgres-logs docker logs "${harness_container}"
        ((PGS3_EVIDENCE_LAST_RC == 0)) || harness_cleanup_failed=1
        evidence_try postgres-remove docker rm --force --volumes "${harness_container}"
        ((PGS3_EVIDENCE_LAST_RC == 0)) || harness_cleanup_failed=1
    fi
    if [[ -n ${harness_network} ]] && docker network inspect "${harness_network}" >/dev/null 2>&1; then
        evidence_try network-remove docker network rm "${harness_network}"
        ((PGS3_EVIDENCE_LAST_RC == 0)) || harness_cleanup_failed=1
    fi
    if [[ -n ${harness_work_dir} && -d ${harness_work_dir} ]]; then
        case ${harness_work_dir} in
            "${TMPDIR:-/tmp}"/pgs3-clients.*) rm -rf -- "${harness_work_dir}" ;;
            *)
                printf 'refusing to remove unexpected work directory: %s\n' "${harness_work_dir}" >&2
                harness_cleanup_failed=1
                ;;
        esac
    fi

    if [[ ${harness_result} == RUNNING ]]; then
        harness_result=FAIL
    fi
    if [[ ${harness_result} == FAIL ]] && ((original_status == 0)); then
        original_status=1
    fi
    if ((original_status != 0)) && [[ ${harness_result} == PASS ]]; then
        harness_result=FAIL
    fi
    if ((harness_cleanup_failed)) && [[ ${harness_result} == PASS ]]; then
        harness_result=FAIL
        original_status=1
    fi
    evidence_finalize "${harness_result}" || original_status=1
    evidence_cleanup
    printf 'acceptance result: %s\nmanifest: %s/manifest.json\n' \
        "${harness_result}" "${PGS3_RUN_DIR}"
    exit "${original_status}"
}
