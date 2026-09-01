#!/usr/bin/env bash
set -euo pipefail

# Run against a database where CREATE EXTENSION pgs3 has completed.
# Example: PGS3_TEST_DSN=postgresql:///pgs3_test tests/sql/concurrency.sh

PGS3_TEST_DSN=${PGS3_TEST_DSN:-postgresql:///postgres}
PGS3_CONCURRENCY_CLIENTS=${PGS3_CONCURRENCY_CLIENTS:-50}
PGS3_CONCURRENCY_ROUNDS=${PGS3_CONCURRENCY_ROUNDS:-20}

case "$PGS3_CONCURRENCY_CLIENTS" in
    ''|*[!0-9]*) echo "PGS3_CONCURRENCY_CLIENTS must be a positive integer" >&2; exit 2 ;;
esac
case "$PGS3_CONCURRENCY_ROUNDS" in
    ''|*[!0-9]*) echo "PGS3_CONCURRENCY_ROUNDS must be a positive integer" >&2; exit 2 ;;
esac
if (( PGS3_CONCURRENCY_CLIENTS < 2 || PGS3_CONCURRENCY_ROUNDS < 1 )); then
    echo "concurrency test needs at least two clients and one round" >&2
    exit 2
fi

pgs3_concurrency_tmp=$(mktemp -d)
pgs3_concurrency_bucket="sql-concurrency-$$-$RANDOM"
pgs3_bucket_created=0
pgs3_copy_gate_app=
pgs3_lifecycle_gate_app=
pgs3_lease_gate_app=
pgs3_background_pids=()
pgs3_race_buckets=()

cleanup() {
    local pid

    if [[ -n $pgs3_copy_gate_app ]]; then
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = '$pgs3_copy_gate_app'" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n $pgs3_lifecycle_gate_app ]]; then
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = '$pgs3_lifecycle_gate_app'" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n $pgs3_lease_gate_app ]]; then
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = '$pgs3_lease_gate_app'" \
            >/dev/null 2>&1 || true
    fi
    for pid in "${pgs3_background_pids[@]}"; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    for pid in "${pgs3_background_pids[@]}"; do
        wait "$pid" >/dev/null 2>&1 || true
    done
    if (( pgs3_bucket_created )); then
        psql "$PGS3_TEST_DSN" -X -q -v ON_ERROR_STOP=1 \
            -c "DELETE FROM pgs3.upload AS u USING pgs3.bucket AS b WHERE u.bucket_id = b.bucket_id AND b.name = '$pgs3_concurrency_bucket'" \
            -c "SELECT pgs3.delete('$pgs3_concurrency_bucket', key, version_id) FROM pgs3.list_versions('$pgs3_concurrency_bucket', p_max_keys => 1000)" \
            -c "SELECT pgs3.delete_bucket('$pgs3_concurrency_bucket')" \
            >/dev/null 2>&1 || true
    fi
    for bucket in "${pgs3_race_buckets[@]}"; do
        psql "$PGS3_TEST_DSN" -X -q -v ON_ERROR_STOP=1 \
            -c "DELETE FROM pgs3.upload AS u USING pgs3.bucket AS b WHERE u.bucket_id = b.bucket_id AND b.name = '$bucket'" \
            -c "DELETE FROM pgs3.object AS o USING pgs3.bucket AS b WHERE o.bucket_id = b.bucket_id AND b.name = '$bucket'" \
            -c "DELETE FROM pgs3.bucket AS b WHERE b.name = '$bucket'" \
            >/dev/null 2>&1 || true
    done
    rm -r -- "$pgs3_concurrency_tmp"
}
trap cleanup EXIT INT TERM

psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
    -c "SELECT pgs3.create_bucket('$pgs3_concurrency_bucket')" >/dev/null
pgs3_bucket_created=1

export PGS3_TEST_DSN
export pgs3_concurrency_bucket
export pgs3_concurrency_tmp

pgs3_concurrency_worker() {
    local worker_number=$1
    local worker_log="$pgs3_concurrency_tmp/$PGS3_PHASE-$worker_number.log"
    local sql

    if [[ $PGS3_PHASE == if_none_* ]]; then
        sql="SELECT pgs3.put('$pgs3_concurrency_bucket', '$PGS3_KEY', convert_to('writer-$worker_number', 'UTF8'), p_if_none_match => '*')"
    else
        sql="SELECT pgs3.put('$pgs3_concurrency_bucket', '$PGS3_KEY', convert_to('writer-$worker_number', 'UTF8'), p_if_match => '$PGS3_ETAG')"
    fi

    if psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c '\set VERBOSITY verbose' -c "$sql" >"$worker_log" 2>&1; then
        printf 'ok\n' >>"$PGS3_STATUS_FILE"
    elif grep -q 'P3C01' "$worker_log"; then
        printf 'precondition\n' >>"$PGS3_STATUS_FILE"
    else
        printf 'unexpected\n' >>"$PGS3_STATUS_FILE"
    fi
}
export -f pgs3_concurrency_worker

pgs3_idempotent_create_worker() {
    local worker_number=$1
    local worker_log="$pgs3_concurrency_tmp/idempotent-create-$worker_number.log"

    if psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pgs3.create_bucket('$pgs3_concurrency_bucket', '{\"region\":\"us-east-1\",\"attempt\":\"replacement\"}'::jsonb)" \
        >"$worker_log" 2>&1; then
        printf 'ok\n' >>"$PGS3_IDEMPOTENT_CREATE_STATUS_FILE"
    else
        printf 'unexpected\n' >>"$PGS3_IDEMPOTENT_CREATE_STATUS_FILE"
    fi
}
export -f pgs3_idempotent_create_worker

run_phase() {
    local phase=$1
    local key=$2
    local etag=${3:-}
    local status_file="$pgs3_concurrency_tmp/$phase.status"
    local ok_count
    local precondition_count
    local unexpected_count

    : >"$status_file"
    export PGS3_PHASE=$phase
    export PGS3_KEY=$key
    export PGS3_ETAG=$etag
    export PGS3_STATUS_FILE=$status_file

    seq 1 "$PGS3_CONCURRENCY_CLIENTS" \
        | xargs -P "$PGS3_CONCURRENCY_CLIENTS" -n 1 \
            bash -c 'pgs3_concurrency_worker "$1"' _

    ok_count=$(grep -c '^ok$' "$status_file" || true)
    precondition_count=$(grep -c '^precondition$' "$status_file" || true)
    unexpected_count=$(grep -c '^unexpected$' "$status_file" || true)
    if (( ok_count != 1
          || precondition_count != PGS3_CONCURRENCY_CLIENTS - 1
          || unexpected_count != 0 )); then
        echo "$phase failed: success=$ok_count precondition=$precondition_count unexpected=$unexpected_count" >&2
        for worker_log in "$pgs3_concurrency_tmp/$phase-"*.log; do
            if ! grep -Eq 'P3C01|^\(' "$worker_log"; then
                echo "--- $worker_log" >&2
                sed -n '1,80p' "$worker_log" >&2
            fi
        done
        return 1
    fi
}

run_idempotent_create_phase() {
    local status_file="$pgs3_concurrency_tmp/idempotent-create.status"
    local bucket_before
    local bucket_after
    local objects_before
    local objects_after
    local ok_count
    local unexpected_count

    bucket_before=$(psql "$PGS3_TEST_DSN" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -c "SELECT bucket_id, created_at, config FROM pgs3.bucket WHERE name = '$pgs3_concurrency_bucket'")
    objects_before=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM pgs3.object AS o JOIN pgs3.bucket AS b USING (bucket_id) WHERE b.name = '$pgs3_concurrency_bucket'")

    : >"$status_file"
    export PGS3_IDEMPOTENT_CREATE_STATUS_FILE=$status_file
    seq 1 "$PGS3_CONCURRENCY_CLIENTS" \
        | xargs -P "$PGS3_CONCURRENCY_CLIENTS" -n 1 \
            bash -c 'pgs3_idempotent_create_worker "$1"' _

    ok_count=$(grep -c '^ok$' "$status_file" || true)
    unexpected_count=$(grep -c '^unexpected$' "$status_file" || true)
    bucket_after=$(psql "$PGS3_TEST_DSN" -X -qAt -F '|' -v ON_ERROR_STOP=1 \
        -c "SELECT bucket_id, created_at, config FROM pgs3.bucket WHERE name = '$pgs3_concurrency_bucket'")
    objects_after=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM pgs3.object AS o JOIN pgs3.bucket AS b USING (bucket_id) WHERE b.name = '$pgs3_concurrency_bucket'")

    if (( ok_count != PGS3_CONCURRENCY_CLIENTS || unexpected_count != 0 )) \
       || [[ $bucket_after != "$bucket_before" || $objects_after != "$objects_before" ]]; then
        echo "idempotent CreateBucket failed: success=$ok_count unexpected=$unexpected_count objects=$objects_before/$objects_after" >&2
        if [[ $bucket_after != "$bucket_before" ]]; then
            echo 'idempotent CreateBucket changed the canonical bucket row' >&2
        fi
        for worker_log in "$pgs3_concurrency_tmp/idempotent-create-"*.log; do
            if [[ -s $worker_log ]]; then
                echo "--- $worker_log" >&2
                sed -n '1,80p' "$worker_log" >&2
            fi
        done
        return 1
    fi
}

wait_for_activity_count() {
    local expected=$1
    local query=$2
    local description=$3
    local value
    local attempt

    for attempt in $(seq 1 200); do
        value=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "$query")
        if [[ $value == "$expected" ]]; then
            return 0
        fi
        sleep 0.05
    done
    echo "timed out waiting for $description (wanted $expected, got ${value:-none})" >&2
    return 1
}

run_delete_child_race() {
    local child_kind=$1
    local child_slug=${child_kind//_/-}
    local race_bucket="sql-delete-$child_slug-$$-$RANDOM"
    local fork_destination="$race_bucket-fork"
    local gate_log="$pgs3_concurrency_tmp/$child_kind-gate.log"
    local delete_log="$pgs3_concurrency_tmp/$child_kind-delete.log"
    local child_log="$pgs3_concurrency_tmp/$child_kind-child.log"
    local delete_app="pgs3-delete-$child_slug-$$"
    local child_app="pgs3-child-$child_slug-$$"
    local child_sql
    local gate_pid
    local delete_pid
    local child_pid
    local delete_status=0
    local child_status=0
    local remaining

    pgs3_race_buckets+=("$race_bucket" "$fork_destination")
    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pgs3.create_bucket('$race_bucket')" >/dev/null

    # A row-level KEY SHARE gate lets delete_bucket finish both emptiness
    # checks and then block at its physical DELETE.  It remains compatible with
    # the FK-side KEY SHARE taken by an object/upload insert.  Historically the
    # child therefore committed behind the completed check and the DELETE
    # surfaced 23503.  The lifecycle protocol makes delete hold the exclusive
    # name lock first, so the child now waits and resolves NoSuchBucket after
    # deletion commits.
    pgs3_lifecycle_gate_app="pgs3-lifecycle-gate-$child_slug-$$"
    PGAPPNAME=$pgs3_lifecycle_gate_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c 'BEGIN' \
            -c "SELECT bucket_id FROM pgs3.bucket WHERE name = '$race_bucket' FOR KEY SHARE" \
            -c "SELECT pg_sleep(30)" \
            -c 'COMMIT' >"$gate_log" 2>&1 &
    gate_pid=$!
    pgs3_background_pids+=("$gate_pid")

    wait_for_activity_count 1 \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$pgs3_lifecycle_gate_app' AND wait_event = 'PgSleep'" \
        "$child_kind row-lock gate"

    PGAPPNAME=$delete_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c '\set VERBOSITY verbose' \
            -c "SET statement_timeout = '20s'" \
            -c "SELECT pgs3.delete_bucket('$race_bucket')" \
            >"$delete_log" 2>&1 &
    delete_pid=$!
    pgs3_background_pids+=("$delete_pid")

    wait_for_activity_count 1 \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$delete_app' AND wait_event_type = 'Lock'" \
        "$child_kind delete to reach the row lock"

    case "$child_kind" in
        put)
            child_sql="SELECT pgs3.put('$race_bucket', 'racing-key', convert_to('racing-body', 'UTF8'))"
            ;;
        begin_upload)
            child_sql="SELECT pgs3.begin_upload('$race_bucket', 'racing-key')"
            ;;
        fork_bucket)
            child_sql="SELECT pgs3.fork_bucket('$race_bucket', '$fork_destination')"
            ;;
        *)
            echo "unknown bucket lifecycle child kind: $child_kind" >&2
            return 2
            ;;
    esac

    PGAPPNAME=$child_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c '\set VERBOSITY verbose' \
            -c "SET statement_timeout = '20s'" \
            -c "$child_sql" >"$child_log" 2>&1 &
    child_pid=$!
    pgs3_background_pids+=("$child_pid")

    wait_for_activity_count 1 \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$child_app' AND wait_event_type = 'Lock'" \
        "$child_kind child to wait on the bucket lifecycle lock"

    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = '$pgs3_lifecycle_gate_app'" \
        >/dev/null
    wait "$gate_pid" >/dev/null 2>&1 || true
    pgs3_lifecycle_gate_app=

    wait "$delete_pid" || delete_status=$?
    wait "$child_pid" || child_status=$?
    pgs3_background_pids=()

    if (( delete_status != 0 || child_status == 0 )) \
       || ! grep -q 'P3B01' "$child_log"; then
        echo "$child_kind bucket deletion race failed: delete=$delete_status child=$child_status" >&2
        sed -n '1,120p' "$delete_log" >&2
        sed -n '1,120p' "$child_log" >&2
        return 1
    fi

    remaining=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT count(*) FROM pgs3.bucket WHERE name IN ('$race_bucket', '$fork_destination')")
    if [[ $remaining != 0 ]]; then
        echo "$child_kind bucket deletion race left $remaining bucket rows" >&2
        return 1
    fi
}

run_shared_lifecycle_parallel_phase() {
    local left_key=lifecycle-left
    local right_key=lifecycle-right
    local gate_log="$pgs3_concurrency_tmp/lifecycle-shared-gate.log"
    local left_log="$pgs3_concurrency_tmp/lifecycle-left.log"
    local right_log="$pgs3_concurrency_tmp/lifecycle-right.log"
    local gate_pid
    local left_pid
    local right_pid

    # A held shared lifecycle lock models a concurrent source fork.  Ordinary
    # child creators must take the compatible shared form; making it exclusive
    # would accidentally serialize every key in the bucket.
    pgs3_lifecycle_gate_app="pgs3-lifecycle-shared-$$"
    PGAPPNAME=$pgs3_lifecycle_gate_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c 'BEGIN' \
            -c "SELECT pgs3._lock_bucket_lifecycle('$pgs3_concurrency_bucket', false)" \
            -c "SELECT pg_sleep(30)" \
            -c 'COMMIT' >"$gate_log" 2>&1 &
    gate_pid=$!
    pgs3_background_pids+=("$gate_pid")

    wait_for_activity_count 1 \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$pgs3_lifecycle_gate_app' AND wait_event = 'PgSleep'" \
        'shared bucket lifecycle gate'

    PGAPPNAME="pgs3-lifecycle-left-$$" \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "SET statement_timeout = '10s'" \
            -c "SELECT pgs3.put('$pgs3_concurrency_bucket', '$left_key', convert_to('left', 'UTF8'))" \
            >"$left_log" 2>&1 &
    left_pid=$!
    pgs3_background_pids+=("$left_pid")

    PGAPPNAME="pgs3-lifecycle-right-$$" \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "SET statement_timeout = '10s'" \
            -c "SELECT pgs3.put('$pgs3_concurrency_bucket', '$right_key', convert_to('right', 'UTF8'))" \
            >"$right_log" 2>&1 &
    right_pid=$!
    pgs3_background_pids+=("$right_pid")

    wait_for_activity_count 2 \
        "SELECT count(*) FROM pgs3.object AS o JOIN pgs3.bucket AS b USING (bucket_id) WHERE b.name = '$pgs3_concurrency_bucket' AND o.key IN ('$left_key', '$right_key') AND o.is_latest" \
        'different-key writers to pass a shared bucket lifecycle holder'

    wait "$left_pid"
    wait "$right_pid"
    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = '$pgs3_lifecycle_gate_app'" \
        >/dev/null
    wait "$gate_pid" >/dev/null 2>&1 || true
    pgs3_lifecycle_gate_app=
    pgs3_background_pids=()
}

run_reciprocal_copy_phase() {
    local left_key=copy-left
    local right_key=copy-right
    local gate_log="$pgs3_concurrency_tmp/copy-gate.log"
    local left_log="$pgs3_concurrency_tmp/copy-left.log"
    local right_log="$pgs3_concurrency_tmp/copy-right.log"
    local left_app="pgs3-copy-left-$$"
    local right_app="pgs3-copy-right-$$"
    local gate_pid
    local left_pid
    local right_pid
    local left_status=0
    local right_status=0
    local copied_equal

    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pgs3.put('$pgs3_concurrency_bucket', '$left_key', convert_to('left', 'UTF8'))" \
        -c "SELECT pgs3.put('$pgs3_concurrency_bucket', '$right_key', convert_to('right', 'UTF8'))" \
        >/dev/null

    # Hold both per-key advisory locks so both reciprocal copy calls reach a
    # genuine lock wait before the gate is released.  With the historical
    # source-row-first order they then acquire opposite destination locks and
    # deterministically deadlock.  The fixed implementation queues both calls
    # on the same first lock and lets them complete serially.
    pgs3_copy_gate_app="pgs3-copy-gate-$$"
    PGAPPNAME=$pgs3_copy_gate_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c 'BEGIN' \
            -c "SELECT pgs3._lock_key((SELECT bucket_id FROM pgs3.bucket WHERE name = '$pgs3_concurrency_bucket'), '$left_key')" \
            -c "SELECT pgs3._lock_key((SELECT bucket_id FROM pgs3.bucket WHERE name = '$pgs3_concurrency_bucket'), '$right_key')" \
            -c "SELECT pg_sleep(30)" \
            -c 'COMMIT' >"$gate_log" 2>&1 &
    gate_pid=$!
    pgs3_background_pids+=("$gate_pid")

    wait_for_activity_count 2 \
        "SELECT count(*) FROM pg_locks AS l JOIN pg_stat_activity AS a USING (pid) WHERE a.application_name = '$pgs3_copy_gate_app' AND l.locktype = 'advisory' AND l.granted" \
        'copy gate advisory locks'

    PGAPPNAME=$left_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "SET statement_timeout = '10s'" \
            -c "SET deadlock_timeout = '100ms'" \
            -c "SELECT pgs3.copy('$pgs3_concurrency_bucket', '$left_key', '$pgs3_concurrency_bucket', '$right_key')" \
            >"$left_log" 2>&1 &
    left_pid=$!
    pgs3_background_pids+=("$left_pid")

    PGAPPNAME=$right_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c "SET statement_timeout = '10s'" \
            -c "SET deadlock_timeout = '100ms'" \
            -c "SELECT pgs3.copy('$pgs3_concurrency_bucket', '$right_key', '$pgs3_concurrency_bucket', '$left_key')" \
            >"$right_log" 2>&1 &
    right_pid=$!
    pgs3_background_pids+=("$right_pid")

    wait_for_activity_count 2 \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name IN ('$left_app', '$right_app') AND wait_event_type = 'Lock'" \
        'both reciprocal CopyObject transactions to block at the gate'

    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = '$pgs3_copy_gate_app'" \
        >/dev/null
    wait "$gate_pid" >/dev/null 2>&1 || true
    pgs3_copy_gate_app=

    wait "$left_pid" || left_status=$?
    wait "$right_pid" || right_status=$?
    pgs3_background_pids=()
    if (( left_status != 0 || right_status != 0 )); then
        echo "reciprocal CopyObject failed: left=$left_status right=$right_status" >&2
        sed -n '1,120p' "$left_log" >&2
        sed -n '1,120p' "$right_log" >&2
        return 1
    fi

    copied_equal=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT (pgs3.get('$pgs3_concurrency_bucket', '$left_key')).body = (pgs3.get('$pgs3_concurrency_bucket', '$right_key')).body")
    if [[ $copied_equal != t ]]; then
        echo 'reciprocal CopyObject calls completed but did not both publish' >&2
        return 1
    fi
}

run_upload_lease_gc_race() {
    local upload_id
    local renew_log="$pgs3_concurrency_tmp/upload-lease-renew.log"
    local renew_pid
    local renew_status=0
    local survived

    upload_id=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pgs3.begin_upload('$pgs3_concurrency_bucket', 'lease-gc-race')")
    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "UPDATE pgs3.upload SET updated_at = clock_timestamp() - interval '48 hours', lease_expires_at = clock_timestamp() - interval '1 hour' WHERE upload_id = '$upload_id'" \
        >/dev/null

    # renew_upload takes the same row lock as chunk/part/complete/list/abort.
    # While that transaction is active, operator GC must use SKIP LOCKED rather
    # than wait for it or delete from an earlier eligibility snapshot.
    pgs3_lease_gate_app="pgs3-upload-lease-renew-$$"
    PGAPPNAME=$pgs3_lease_gate_app \
        psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
            -c 'BEGIN' \
            -c "SELECT pgs3.renew_upload('$upload_id')" \
            -c "SELECT pg_sleep(2)" \
            -c 'COMMIT' >"$renew_log" 2>&1 &
    renew_pid=$!
    pgs3_background_pids+=("$renew_pid")

    wait_for_activity_count 1 \
        "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$pgs3_lease_gate_app' AND wait_event = 'PgSleep'" \
        'upload lease renewal to hold the row lock'

    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SET statement_timeout = '1s'" \
        -c "SELECT pgs3.gc_pending_uploads(interval '24 hours', 100000)" \
        >/dev/null
    survived=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT EXISTS (SELECT 1 FROM pgs3.upload WHERE upload_id = '$upload_id')")
    if [[ $survived != t ]]; then
        echo 'pending GC deleted an upload locked by concurrent renewal' >&2
        return 1
    fi

    wait "$renew_pid" || renew_status=$?
    pgs3_lease_gate_app=
    pgs3_background_pids=()
    if (( renew_status != 0 )); then
        echo "upload lease renewal failed: status=$renew_status" >&2
        sed -n '1,120p' "$renew_log" >&2
        return 1
    fi

    # updated_at is intentionally still old.  A second GC after the lock is
    # released must retain the row because the committed deadline is live.
    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT pgs3.gc_pending_uploads(interval '24 hours', 100000)" \
        >/dev/null
    survived=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT EXISTS (SELECT 1 FROM pgs3.upload WHERE upload_id = '$upload_id' AND lease_expires_at > clock_timestamp() AND updated_at < clock_timestamp() - interval '24 hours')")
    if [[ $survived != t ]]; then
        echo 'pending GC deleted an aged upload after its lease renewal committed' >&2
        return 1
    fi

    psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "UPDATE pgs3.upload SET lease_expires_at = clock_timestamp() - interval '1 hour' WHERE upload_id = '$upload_id'" \
        -c "SELECT pgs3.gc_pending_uploads(interval '24 hours', 100000)" \
        >/dev/null
    survived=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT EXISTS (SELECT 1 FROM pgs3.upload WHERE upload_id = '$upload_id')")
    if [[ $survived != f ]]; then
        echo 'pending GC retained an aged upload after its lease expired' >&2
        return 1
    fi
}

for round in $(seq 1 "$PGS3_CONCURRENCY_ROUNDS"); do
    if_none_key="if-none-$round"
    if_match_key="if-match-$round"

    run_phase "if_none_$round" "$if_none_key"

    initial_etag=$(psql "$PGS3_TEST_DSN" -X -qAt -v ON_ERROR_STOP=1 \
        -c "SELECT (pgs3.put('$pgs3_concurrency_bucket', '$if_match_key', convert_to('initial', 'UTF8'))).etag")
    run_phase "if_match_$round" "$if_match_key" "$initial_etag"
done

run_idempotent_create_phase
run_reciprocal_copy_phase
run_delete_child_race put
run_delete_child_race begin_upload
run_delete_child_race fork_bucket
run_shared_lifecycle_parallel_phase
run_upload_lease_gc_race

echo "pgs3 concurrency: conditions, idempotent bucket create, reciprocal copy, bucket lifecycle, and upload lease/GC races passed"
