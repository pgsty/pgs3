#!/usr/bin/env bash
# shellcheck shell=bash

REL_LAST_CONTAINER=''
REL_SLOW_PID=''
REL_SLOW_LOG=''

rel_start_server() {
    local suffix=$1 volume=$2 alias=$3 host_port=$4 second_host_port=${5:-0}
    local container="pgs3-rel-${suffix}-${REL_RUN_TAG}"
    local -a arguments=(
        run --detach
        --name "${container}"
        --label "pgs3.reliability.run=${REL_RUN_TAG}"
        --network "${REL_NETWORK}"
        --network-alias "${alias}"
        --volume "${volume}:/var/lib/postgresql/data"
        --env PGDATA=/var/lib/postgresql/data
        --env POSTGRES_HOST_AUTH_METHOD=trust
        --env POSTGRES_INITDB_ARGS=--data-checksums
        --shm-size 256m
    )
    if ((host_port > 0)); then
        arguments+=(--publish "127.0.0.1:${host_port}:9000")
    fi
    if ((second_host_port > 0)); then
        arguments+=(--publish "127.0.0.1:${second_host_port}:9001")
    fi
    arguments+=(
        "${REL_IMAGE}"
        postgres
        -c shared_preload_libraries=pgs3
        -c "listen_addresses=*"
        -c max_worker_processes=40
        -c wal_level=replica
        -c max_wal_senders=10
        -c max_replication_slots=10
        -c hot_standby=on
        -c log_min_messages=info
        -c "log_line_prefix=%m [%p] %q%u@%d "
    )
    rel_track_container "${container}"
    evidence_run "server-start-${suffix}" docker "${arguments[@]}"
    REL_LAST_CONTAINER=${container}
}

rel_prepare_static_server() {
    local container=$1 host_port=$2 workers=$3 statement_timeout=$4
    evidence_run "postgres-ready-${container}" rel_wait_postgres "${container}"
    evidence_run "extension-bootstrap-${container}" rel_bootstrap_extension "${container}"
    evidence_run "static-config-${container}" rel_configure_static \
        "${container}" 0.0.0.0 9000 "${workers}" "${statement_timeout}"
    evidence_run "workers-ready-${container}" rel_wait_primary_workers \
        "${container}" "${workers}" 9000 0.0.0.0
    evidence_run "endpoint-ready-${container}" rel_wait_port "${host_port}"
}

rel_storage_counts() {
    local container=$1
    rel_scalar "${container}" \
        "SELECT (SELECT count(*) FROM pgs3.upload) || '|' || (SELECT count(*) FROM pgs3.upload_chunk) || '|' || (SELECT count(*) FROM pgs3.upload_part) || '|' || (SELECT count(*) FROM pgs3.blob) || '|' || (SELECT count(*) FROM pgs3.chunk) || '|' || (SELECT count(*) FROM pgs3.blob_extent) || '|' || (SELECT count(*) FROM pgs3.object)"
}

rel_start_slow_put() {
    local host_port=$1 bucket=$2 key=$3 seed=$4 size=$5 delay_ms=${6:-50}
    REL_SLOW_LOG="${REL_TMP_DIR}/slow-put-${key}.log"
    rel_s3 slow-put \
        --endpoint "$(rel_endpoint "${host_port}")" \
        --bucket "${bucket}" --key "${key}" \
        --size "${size}" --seed "${seed}" \
        --chunk-size 65536 --delay-ms "${delay_ms}" \
        >"${REL_SLOW_LOG}" 2>&1 &
    REL_SLOW_PID=$!
    rel_track_host_pid "${REL_SLOW_PID}"
    printf 'started slow PutObject client pid=%s\n' "${REL_SLOW_PID}"
}

rel_wait_upload_chunks() {
    local container=$1 bucket=$2 key=$3 minimum=$4
    local count=0
    for _ in $(seq 1 120); do
        count=$(rel_scalar "${container}" \
            "SELECT count(*) FROM pgs3.upload_chunk c JOIN pgs3.upload u USING (upload_id) JOIN pgs3.bucket b USING (bucket_id) WHERE b.name='${bucket}' AND u.key='${key}'" \
            2>/dev/null || true)
        if [[ ${count:-0} =~ ^[0-9]+$ ]] && ((count >= minimum)); then
            printf 'durable upload chunks observed: %s (minimum %s)\n' "${count}" "${minimum}"
            return 0
        fi
        if ! kill -0 "${REL_SLOW_PID}" >/dev/null 2>&1; then
            printf 'slow PutObject exited before enough chunks were durable\n' >&2
            cat "${REL_SLOW_LOG}" >&2 || true
            return 1
        fi
        sleep 0.25
    done
    printf 'timed out waiting for durable upload chunks; last count=%s\n' "${count}" >&2
    return 1
}

rel_expect_interrupted_slow_put() {
    local status
    if wait "${REL_SLOW_PID}"; then
        status=0
    else
        status=$?
    fi
    cat "${REL_SLOW_LOG}"
    if ((status == 0)); then
        printf 'slow PutObject unexpectedly completed before shutdown/crash\n' >&2
        return 1
    fi
    printf 'slow PutObject was interrupted as expected, exit_status=%s\n' "${status}"
}

rel_gc_crash_upload() {
    local container=$1 bucket=$2 key=$3 expected_baseline=$4
    docker exec --interactive "${container}" psql \
        --username postgres --dbname postgres --no-psqlrc --set ON_ERROR_STOP=1 <<SQL
DO \$pgs3_crash_gc\$
DECLARE
    changed bigint;
    pending_deleted bigint;
BEGIN
    UPDATE pgs3.upload AS u
       SET updated_at = clock_timestamp() - interval '25 hours',
           lease_expires_at = clock_timestamp() - interval '1 minute'
      FROM pgs3.bucket AS b
     WHERE b.bucket_id = u.bucket_id
       AND b.name = '${bucket}'
       AND u.key = '${key}'
       AND u.state = 'pending';
    GET DIAGNOSTICS changed = ROW_COUNT;
    IF changed <> 1 THEN
        RAISE EXCEPTION 'expected one pending crash upload, aged %', changed;
    END IF;
    pending_deleted := pgs3.gc_pending_uploads(interval '24 hours', 1000);
    IF pending_deleted <> 1 THEN
        RAISE EXCEPTION 'expected one pending GC deletion, deleted %', pending_deleted;
    END IF;
    RAISE NOTICE 'expired both retention age and lease, then deleted one pending crash upload';
END
\$pgs3_crash_gc\$;
SQL

    local batch total=0 quiet=0
    for _ in $(seq 1 100); do
        batch=$(rel_scalar "${container}" "SELECT pgs3.gc_blobs(1000)")
        [[ ${batch} =~ ^[0-9]+$ ]]
        total=$((total + batch))
        if ((batch == 0)); then
            quiet=1
            break
        fi
    done
    printf 'unreferenced blobs deleted: %s\n' "${total}"
    ((quiet == 1))

    local after
    after=$(rel_storage_counts "${container}")
    printf 'storage counts (upload|upload_chunk|upload_part|blob|chunk|extent|object): baseline=%s after_gc=%s\n' \
        "${expected_baseline}" "${after}"
    [[ ${after} == "${expected_baseline}" ]]
}

rel_assert_sigkill_exit() {
    local container=$1 wait_status state
    wait_status=$(timeout 10s docker wait "${container}")
    printf 'post-SIGKILL postmaster exit status: %s\n' "${wait_status}"
    [[ ${wait_status} == 137 ]]
    state=$(docker container inspect "${container}" \
        --format '{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}')
    printf 'post-SIGKILL container state: %s\n' "${state}"
    [[ ${state} == 'exited|137|false' ]]
}

scenario_crash() {
    local volume container host_port endpoint bucket committed_key partial_key baseline
    rel_create_volume crash
    volume=${REL_LAST_VOLUME}
    host_port=$(rel_pick_port)
    rel_start_server crash "${volume}" crash-primary "${host_port}"
    container=${REL_LAST_CONTAINER}
    rel_prepare_static_server "${container}" "${host_port}" 2 5000
    endpoint=$(rel_endpoint "${host_port}")
    bucket="crash-${REL_RUN_TAG}"
    committed_key=committed.bin
    partial_key=partial.bin

    evidence_run crash-create-bucket rel_s3 create-bucket \
        --endpoint "${endpoint}" --bucket "${bucket}"
    evidence_run crash-put-committed rel_s3 put \
        --endpoint "${endpoint}" --bucket "${bucket}" --key "${committed_key}" \
        --size 6291473 --seed committed-before-crash
    evidence_run crash-get-before rel_s3 get \
        --endpoint "${endpoint}" --bucket "${bucket}" --key "${committed_key}" \
        --size 6291473 --seed committed-before-crash
    baseline=$(rel_storage_counts "${container}")
    printf 'pre-crash storage baseline: %s\n' "${baseline}"

    evidence_run crash-slow-put-start rel_start_slow_put \
        "${host_port}" "${bucket}" "${partial_key}" partial-at-crash 67108864 50
    evidence_run crash-upload-durable rel_wait_upload_chunks \
        "${container}" "${bucket}" "${partial_key}" 2
    evidence_run crash-upload-is-pending rel_assert_scalar "${container}" \
        "SELECT count(*) FROM pgs3.upload u JOIN pgs3.bucket b USING(bucket_id) WHERE b.name='${bucket}' AND u.key='${partial_key}' AND u.state='pending'" \
        1 "one partial upload is pending"
    # The quoted command is intentionally expanded inside the container.
    # shellcheck disable=SC2016
    evidence_run crash-pid1-is-postmaster docker exec "${container}" sh -ceu \
        'command=$(cat /proc/1/comm); printf "container pid 1 command: %s\n" "$command"; test "$command" = postgres'
    evidence_run crash-postmaster-processes docker top "${container}" -eo pid,ppid,comm,args
    evidence_run crash-sigkill-postmaster docker kill --signal=KILL "${container}"
    evidence_run crash-client-interrupted rel_expect_interrupted_slow_put
    evidence_run crash-sigkill-exit rel_assert_sigkill_exit "${container}"

    evidence_run crash-restart docker start "${container}"
    evidence_run crash-recovery-ready rel_wait_postgres "${container}"
    evidence_run crash-workers-recovered rel_wait_primary_workers \
        "${container}" 2 9000 0.0.0.0
    evidence_run crash-endpoint-recovered rel_wait_port "${host_port}"
    evidence_run crash-committed-sha256 rel_s3 get \
        --endpoint "${endpoint}" --bucket "${bucket}" --key "${committed_key}" \
        --size 6291473 --seed committed-before-crash
    evidence_run crash-partial-invisible rel_s3 not-visible \
        --endpoint "${endpoint}" --bucket "${bucket}" --key "${partial_key}"
    evidence_run crash-pending-survived rel_assert_scalar "${container}" \
        "SELECT count(*) FROM pgs3.upload u JOIN pgs3.bucket b USING(bucket_id) WHERE b.name='${bucket}' AND u.key='${partial_key}' AND u.state='pending'" \
        1 "crash-left pending upload is recoverable by GC"
    evidence_run crash-gc-cleanup rel_gc_crash_upload \
        "${container}" "${bucket}" "${partial_key}" "${baseline}"
    evidence_run crash-committed-after-gc rel_s3 get \
        --endpoint "${endpoint}" --bucket "${bucket}" --key "${committed_key}" \
        --size 6291473 --seed committed-before-crash
}

rel_log_count() {
    local container=$1 needle=$2
    docker logs "${container}" 2>&1 | awk -v needle="${needle}" '
        index($0, needle) { count += 1 }
        END { print count + 0 }
    '
}

rel_pg_ctl_fast_stop() {
    local container=$1 started finished elapsed command_finished command_elapsed
    local status wait_command_status wait_status state
    local fast_before fast_after fast_expected clean_before clean_after clean_expected
    fast_before=$(rel_log_count "${container}" 'received fast shutdown request')
    clean_before=$(rel_log_count "${container}" 'database system is shut down')
    [[ ${fast_before} =~ ^[0-9]+$ && ${clean_before} =~ ^[0-9]+$ ]]
    started=$(date +%s%N)
    if timeout --signal=TERM 7s docker exec --user postgres "${container}" \
        pg_ctl stop -D /var/lib/postgresql/data -m fast -t 5; then
        status=0
    else
        status=$?
    fi
    command_finished=$(date +%s%N)
    command_elapsed=$(((command_finished - started) / 1000000))
    printf 'pg_ctl exit_status=%s command_elapsed_ms=%s\n' \
        "${status}" "${command_elapsed}"
    case ${status} in
        0)
            printf 'pg_ctl completed before the target PID namespace was destroyed\n'
            ;;
        124)
            printf 'outer pg_ctl command timeout expired after 7 seconds\n' >&2
            return 1
            ;;
        137)
            printf 'pg_ctl exec was killed when the target PID namespace was destroyed; validating the target exit and shutdown log\n'
            ;;
        *)
            printf 'pg_ctl failed before clean target shutdown: exit_status=%s\n' \
                "${status}" >&2
            return 1
            ;;
    esac
    if wait_status=$(timeout --signal=TERM 2s docker wait "${container}"); then
        wait_command_status=0
    else
        wait_command_status=$?
    fi
    if ((wait_command_status != 0)); then
        printf 'docker wait failed after pg_ctl: exit_status=%s\n' \
            "${wait_command_status}" >&2
        return 1
    fi
    finished=$(date +%s%N)
    elapsed=$(((finished - started) / 1000000))
    printf 'target shutdown elapsed_ms=%s\n' "${elapsed}"
    ((elapsed < 5000))
    printf 'container process exit status: %s\n' "${wait_status}"
    [[ ${wait_status} == 0 ]]
    state=$(docker container inspect "${container}" \
        --format '{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Error}}')
    printf 'post-stop container state: %s\n' "${state}"
    [[ ${state} == 'exited|0|false|' ]]
    fast_after=$(rel_log_count "${container}" 'received fast shutdown request')
    clean_after=$(rel_log_count "${container}" 'database system is shut down')
    fast_expected=$((fast_before + 1))
    clean_expected=$((clean_before + 1))
    printf 'fast shutdown request log count: before=%s after=%s expected=%s\n' \
        "${fast_before}" "${fast_after}" "${fast_expected}"
    [[ ${fast_after} == "${fast_expected}" ]]
    printf 'clean shutdown log count: before=%s after=%s expected=%s\n' \
        "${clean_before}" "${clean_after}" "${clean_expected}"
    [[ ${clean_after} == "${clean_expected}" ]]
}

scenario_fast_stop() {
    local volume container host_port endpoint bucket
    rel_create_volume fast-stop
    volume=${REL_LAST_VOLUME}
    host_port=$(rel_pick_port)
    rel_start_server fast-stop "${volume}" fast-stop-primary "${host_port}"
    container=${REL_LAST_CONTAINER}
    rel_prepare_static_server "${container}" "${host_port}" 4 5000
    endpoint=$(rel_endpoint "${host_port}")
    bucket="stop-${REL_RUN_TAG}"
    evidence_run stop-create-bucket rel_s3 create-bucket \
        --endpoint "${endpoint}" --bucket "${bucket}"
    evidence_run stop-slow-put-start rel_start_slow_put \
        "${host_port}" "${bucket}" shutdown-in-flight.bin shutdown-in-flight 67108864 50
    evidence_run stop-upload-durable rel_wait_upload_chunks \
        "${container}" "${bucket}" shutdown-in-flight.bin 1
    evidence_run stop-pg-ctl-fast rel_pg_ctl_fast_stop "${container}"
    evidence_run stop-client-interrupted rel_expect_interrupted_slow_put
}

rel_reload_configuration() {
    local container=$1 new_addr=$2
    docker exec --interactive "${container}" psql \
        --username postgres --dbname postgres --no-psqlrc --set ON_ERROR_STOP=1 \
        --set new_addr="${new_addr}" <<'SQL'
ALTER SYSTEM SET pgs3.workers = '2';
ALTER SYSTEM SET pgs3.port = '9001';
ALTER SYSTEM SET pgs3.listen_addr = :'new_addr';
ALTER SYSTEM SET pgs3.statement_timeout_ms = '250';
SELECT pg_reload_conf();
SQL
}

rel_assert_retired_pids() {
    local container=$1 pids=$2
    [[ ${pids} =~ ^[0-9]+(,[0-9]+)*$ ]]
    rel_wait_scalar "${container}" \
        "SELECT count(*) = 0 FROM pg_stat_activity WHERE pid IN (${pids})" \
        t "scaled-down HTTP worker PIDs exited" 30
}

rel_lock_bucket_table() {
    local container=$1 log_file=$2
    docker exec "${container}" psql --username postgres --dbname postgres \
        --no-psqlrc --set ON_ERROR_STOP=1 \
        --command "BEGIN; LOCK TABLE pgs3.bucket IN ACCESS EXCLUSIVE MODE; SELECT pg_sleep(30); COMMIT;" \
        >"${log_file}" 2>&1 &
    REL_SLOW_PID=$!
    rel_track_host_pid "${REL_SLOW_PID}"
    printf 'table-lock holder pid=%s\n' "${REL_SLOW_PID}"
}

rel_wait_lock_holder() {
    local container=$1
    rel_wait_scalar "${container}" \
        "SELECT EXISTS (SELECT 1 FROM pg_locks l WHERE l.relation='pgs3.bucket'::regclass AND l.mode='AccessExclusiveLock' AND l.granted AND l.pid <> pg_backend_pid())" \
        t "bucket table lock acquired" 20
}

rel_finish_lock_holder() {
    local container=$1 log_file=$2 cancelled status
    cancelled=$(rel_scalar "${container}" \
        "SELECT count(*) FROM (SELECT pg_cancel_backend(l.pid) AS cancelled FROM pg_locks l WHERE l.relation='pgs3.bucket'::regclass AND l.mode='AccessExclusiveLock' AND l.granted AND l.pid <> pg_backend_pid()) AS holders WHERE cancelled")
    printf 'cancelled bucket table lock holders: %s\n' "${cancelled}"
    [[ ${cancelled} == 1 ]]
    if wait "${REL_SLOW_PID}"; then
        status=0
    else
        status=$?
    fi
    cat "${log_file}"
    if ((status == 0)); then
        printf 'bucket table lock holder completed before explicit release\n' >&2
        return 1
    fi
    grep -F 'canceling statement due to user request' "${log_file}"
    printf 'bucket table lock holder released after timeout assertion, exit_status=%s\n' \
        "${status}"
}

scenario_reload() {
    local volume container old_port new_port old_endpoint new_endpoint bucket new_addr old_pids lock_log
    rel_create_volume reload
    volume=${REL_LAST_VOLUME}
    old_port=$(rel_pick_port)
    new_port=$(rel_pick_port)
    while [[ ${new_port} == "${old_port}" ]]; do new_port=$(rel_pick_port); done
    rel_start_server reload "${volume}" reload-primary "${old_port}" "${new_port}"
    container=${REL_LAST_CONTAINER}
    rel_prepare_static_server "${container}" "${old_port}" 4 5000
    old_endpoint=$(rel_endpoint "${old_port}")
    new_endpoint=$(rel_endpoint "${new_port}")
    bucket="reload-${REL_RUN_TAG}"
    evidence_run reload-create-bucket rel_s3 create-bucket \
        --endpoint "${old_endpoint}" --bucket "${bucket}"
    evidence_run reload-put-sentinel rel_s3 put \
        --endpoint "${old_endpoint}" --bucket "${bucket}" --key sentinel.bin \
        --size 1048593 --seed reload-sentinel

    old_pids=$(docker exec "${container}" psql --username postgres --dbname postgres \
        --no-psqlrc --tuples-only --no-align \
        --command "SELECT pid FROM pgs3.worker_state WHERE worker_kind='http' AND worker_slot >= 2 AND desired ORDER BY pid" \
        | paste -sd, -)
    printf 'HTTP PIDs expected to retire during scale-down: %s\n' "${old_pids}"
    [[ ${old_pids} =~ ^[0-9]+,[0-9]+$ ]]
    new_addr=$(rel_container_ip "${container}")
    [[ ${new_addr} =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
    evidence_run reload-sighup rel_reload_configuration "${container}" "${new_addr}"
    evidence_run reload-workers-converged rel_wait_primary_workers \
        "${container}" 2 9001 "${new_addr}"
    evidence_run reload-retired-workers rel_assert_retired_pids "${container}" "${old_pids}"
    evidence_run reload-old-listener-gone rel_wait_container_listener_gone \
        "${container}" 9000
    evidence_run reload-new-port-open rel_wait_port "${new_port}"
    evidence_run reload-new-endpoint-get rel_s3 get \
        --endpoint "${new_endpoint}" --bucket "${bucket}" --key sentinel.bin \
        --size 1048593 --seed reload-sentinel
    evidence_run reload-pg-settings rel_assert_scalar "${container}" \
        "SELECT string_agg(name || '=' || setting, ',' ORDER BY name) FROM pg_settings WHERE name IN ('pgs3.listen_addr','pgs3.port','pgs3.statement_timeout_ms','pgs3.workers')" \
        "pgs3.listen_addr=${new_addr},pgs3.port=9001,pgs3.statement_timeout_ms=250,pgs3.workers=2" \
        "reloaded GUC values"

    lock_log="${REL_TMP_DIR}/reload-lock-holder.log"
    evidence_run reload-lock-start rel_lock_bucket_table "${container}" "${lock_log}"
    evidence_run reload-lock-ready rel_wait_lock_holder "${container}"
    evidence_run reload-statement-timeout rel_s3 expect-error \
        --endpoint "${new_endpoint}" --operation ReloadedStatementTimeout \
        --method GET --bucket "${bucket}" --list-v2 \
        --status 503 --code SlowDown --max-elapsed 2
    evidence_run reload-lock-finish rel_finish_lock_holder "${container}" "${lock_log}"
    evidence_run reload-server-survived rel_wait_primary_workers \
        "${container}" 2 9001 "${new_addr}"
}

rel_enable_replication_access() {
    local container=$1
    docker exec --interactive "${container}" psql \
        --username postgres --dbname postgres --no-psqlrc --set ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE pgs3_replicator LOGIN REPLICATION;
SQL
    docker exec --user postgres "${container}" sh -c \
        "umask 077; printf '%s\\n' 'host replication pgs3_replicator 0.0.0.0/0 trust' >> /var/lib/postgresql/data/pg_hba.conf"
    docker exec "${container}" psql --username postgres --dbname postgres \
        --no-psqlrc --set ON_ERROR_STOP=1 \
        --command 'SELECT pg_reload_conf()'
}

rel_basebackup() {
    local primary=$1 primary_alias=$2 standby_volume=$3 uid gid owner_helper backup_helper
    uid=$(docker exec "${primary}" id -u postgres)
    gid=$(docker exec "${primary}" id -g postgres)
    [[ ${uid} =~ ^[0-9]+$ && ${gid} =~ ^[0-9]+$ ]]
    owner_helper="pgs3-rel-basebackup-owner-${REL_RUN_TAG}"
    backup_helper="pgs3-rel-basebackup-${REL_RUN_TAG}"
    rel_track_container "${owner_helper}"
    rel_track_container "${backup_helper}"
    docker run --rm \
        --name "${owner_helper}" \
        --label "pgs3.reliability.run=${REL_RUN_TAG}" \
        --volume "${standby_volume}:/var/lib/postgresql/data" \
        --entrypoint chown "${REL_IMAGE}" -R "${uid}:${gid}" /var/lib/postgresql/data
    docker run --rm \
        --name "${backup_helper}" \
        --label "pgs3.reliability.run=${REL_RUN_TAG}" \
        --user "${uid}:${gid}" --network "${REL_NETWORK}" \
        --volume "${standby_volume}:/var/lib/postgresql/data" \
        --entrypoint pg_basebackup "${REL_IMAGE}" \
        --host "${primary_alias}" --username pgs3_replicator \
        --pgdata /var/lib/postgresql/data --write-recovery-conf \
        --wal-method stream --checkpoint fast --progress
}

rel_assert_standby_survived() {
    local container=$1
    rel_assert_scalar "${container}" "SELECT pg_is_in_recovery()" t \
        "standby remains in recovery"
    rel_assert_scalar "${container}" \
        "SELECT count(*) FROM pg_stat_activity WHERE backend_type='pgs3 launcher'" \
        1 "preloaded launcher remains alive"
    rel_assert_scalar "${container}" \
        "SELECT count(*) FROM pg_stat_activity WHERE backend_type='pgs3 http'" \
        2 "dynamic HTTP children remain alive"
}

scenario_standby() {
    if [[ ${REL_PG_MAJOR} != 17 ]]; then
        printf 'standby gate is specified for PostgreSQL 17, not PG%s\n' "${REL_PG_MAJOR}" >&2
        return 2
    fi
    local primary_volume standby_volume primary standby primary_port standby_port primary_endpoint standby_endpoint bucket
    local primary_alias="standby-primary-${REL_RUN_TAG}"
    rel_create_volume standby-primary
    primary_volume=${REL_LAST_VOLUME}
    primary_port=$(rel_pick_port)
    rel_start_server standby-primary "${primary_volume}" "${primary_alias}" "${primary_port}"
    primary=${REL_LAST_CONTAINER}
    rel_prepare_static_server "${primary}" "${primary_port}" 2 5000
    primary_endpoint=$(rel_endpoint "${primary_port}")
    bucket="standby-${REL_RUN_TAG}"
    evidence_run standby-create-bucket rel_s3 create-bucket \
        --endpoint "${primary_endpoint}" --bucket "${bucket}"
    evidence_run standby-put-primary rel_s3 put \
        --endpoint "${primary_endpoint}" --bucket "${bucket}" --key replicated.bin \
        --size 3145745 --seed replicated-object
    evidence_run standby-replication-role rel_enable_replication_access "${primary}"

    rel_create_volume standby-copy
    standby_volume=${REL_LAST_VOLUME}
    evidence_run standby-basebackup rel_basebackup \
        "${primary}" "${primary_alias}" "${standby_volume}"
    standby_port=$(rel_pick_port)
    rel_start_server standby "${standby_volume}" "standby-${REL_RUN_TAG}" "${standby_port}"
    standby=${REL_LAST_CONTAINER}
    evidence_run standby-postgres-ready rel_wait_postgres "${standby}"
    evidence_run standby-recovery-state rel_assert_scalar "${standby}" \
        "SELECT pg_is_in_recovery()" t "physical replica is in recovery"
    evidence_run standby-streaming-state rel_wait_scalar "${primary}" \
        "SELECT EXISTS (SELECT 1 FROM pg_stat_replication WHERE state='streaming')" \
        t "standby WAL receiver is streaming" 90
    evidence_run standby-object-replayed rel_wait_scalar "${standby}" \
        "SELECT EXISTS (SELECT 1 FROM pgs3.object o JOIN pgs3.bucket b USING(bucket_id) WHERE b.name='${bucket}' AND o.key='replicated.bin' AND o.is_latest AND NOT o.delete_marker)" \
        t "object row replayed to standby" 90
    evidence_run standby-workers-ready rel_wait_standby_workers "${standby}" 2
    evidence_run standby-endpoint-ready rel_wait_port "${standby_port}"
    standby_endpoint=$(rel_endpoint "${standby_port}")
    evidence_run standby-get rel_s3 get \
        --endpoint "${standby_endpoint}" --bucket "${bucket}" --key replicated.bin \
        --size 3145745 --seed replicated-object
    evidence_run standby-list rel_s3 list-contains \
        --endpoint "${standby_endpoint}" --bucket "${bucket}" \
        --key replicated.bin --prefix replicated
    evidence_run standby-put-rejected-before-body rel_s3 early-put-error \
        --endpoint "${standby_endpoint}" \
        --bucket "${bucket}" --key forbidden.bin --size 4096 \
        --seed forbidden-standby-write --status 503 --code ServiceUnavailable \
        --message 'read-only standby'
    evidence_run standby-no-partial-write rel_s3 not-visible \
        --endpoint "${standby_endpoint}" --bucket "${bucket}" --key forbidden.bin
    evidence_run standby-processes-survived rel_assert_standby_survived "${standby}"
}
