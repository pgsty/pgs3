#!/usr/bin/env bash
set -uo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_dir}" || exit 1

declare -a acceptance_names=()
declare -a acceptance_results=()
declare -a acceptance_codes=()
acceptance_failed=0

record_gate() {
    local name=$1 status=$2 rc=$3
    printf '[%s] %s (exit=%s)\n' "${name}" "${status}" "${rc}"
    acceptance_names+=("${name}")
    acceptance_results+=("${status}")
    acceptance_codes+=("${rc}")
    if ((rc != 0)); then
        acceptance_failed=1
    fi
}

run_gate() {
    local name=$1
    shift

    local status rc
    printf '\n[%s] START\n' "${name}"
    if "$@"; then
        status=PASS
        rc=0
    else
        rc=$?
        if ((rc == 125)); then
            status=BLOCKED
        else
            status=FAIL
        fi
    fi
    record_gate "${name}" "${status}" "${rc}"
}

run_host_pg_gate() {
    local name=$1 target=$2 major=$3 pg_config
    pg_config=$(make --no-print-directory --silent print-pg-config \
        "PG_MAJOR=${major}")
    if [[ ! -x ${pg_config} ]]; then
        printf '\n[%s] START\n' "${name}"
        printf 'BLOCKED: PostgreSQL %s pg_config is unavailable: %s\n' \
            "${major}" "${pg_config}" >&2
        record_gate "${name}" BLOCKED 125
        return
    fi
    run_gate "${name}" make "${target}" "PG_MAJOR=${major}"
}

run_gate fmt-check make fmt-check
run_host_pg_gate check-pg17 check 17
run_host_pg_gate check-pg18 check 18
run_host_pg_gate clippy-pg17 clippy 17
run_host_pg_gate clippy-pg18 clippy 18
run_host_pg_gate lib-unit-pg17 lib-unit 17
run_host_pg_gate lib-unit-pg18 lib-unit 18
run_gate wire-unit make unit
run_host_pg_gate package-pg17 package 17
run_host_pg_gate package-pg18 package 18
run_gate sql-pg17 make sql-test PG_MAJOR=17
run_gate sql-pg18 make sql-test PG_MAJOR=18
run_gate upgrade-pg17 make upgrade-test PG_MAJOR=17
run_gate upgrade-pg18 make upgrade-test PG_MAJOR=18
run_gate integration-lint make integration-lint
run_gate clients-pg17 tests/integration/run-acceptance.sh --mode clients --pg 17
run_gate clients-pg18 tests/integration/run-acceptance.sh --mode clients --pg 18
run_gate ceph-pg17 make ceph-test PG_MAJOR=17
run_gate reliability-pg17 make reliability-test PG_MAJOR=17
run_gate robustness-pg17 make robustness-test PG_MAJOR=17
run_gate fuzz-pg17 make fuzz-test PG_MAJOR=17
run_gate scale-pg17 make scale-test PG_MAJOR=17
run_gate benchmark-pg17 make benchmark-test PG_MAJOR=17

printf '\nAcceptance gate summary\n'
for ((i = 0; i < ${#acceptance_names[@]}; i++)); do
    printf '%-24s %s (exit=%s)\n' \
        "${acceptance_names[$i]}" \
        "${acceptance_results[$i]}" \
        "${acceptance_codes[$i]}"
done

if ((acceptance_failed)); then
    printf 'acceptance result: FAIL\n' >&2
    exit 1
fi

printf 'acceptance result: PASS\n'
