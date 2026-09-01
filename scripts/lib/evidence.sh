#!/usr/bin/env bash
# shellcheck shell=bash

if [[ -n ${PGS3_EVIDENCE_LIB_LOADED:-} ]]; then
    return 0
fi
readonly PGS3_EVIDENCE_LIB_LOADED=1

evidence_script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly evidence_helper="${evidence_script_dir}/evidence.py"

evidence_utc() {
    date -u +'%Y-%m-%dT%H:%M:%SZ'
}

evidence_quote_command() {
    local rendered='' argument quoted
    for argument in "$@"; do
        printf -v quoted '%q' "${argument}"
        rendered+="${rendered:+ }${quoted}"
    done
    printf '%s' "${rendered}"
}

# Keep step functions in the current shell so deliberate state changes (for
# example REL_LAST_CONTAINER) remain visible to the scenario.  This extra call
# frame gives the ERR trap in evidence_run a safe place to return to.
_evidence_execute_step() {
    "$@"
}

evidence_init() {
    local repo_dir=$1 suite=$2 pg_major=$3 requested_id=${4:-}
    local run_id
    if [[ -n ${requested_id} ]]; then
        if [[ ! ${requested_id} =~ ^[A-Za-z0-9._-]+$ ]]; then
            printf 'run id may contain only letters, digits, dot, underscore, and hyphen\n' >&2
            return 2
        fi
        run_id=${requested_id}
    else
        run_id=$(date -u +'%Y%m%dT%H%M%SZ')-"${suite}"-pg"${pg_major}"-$$
    fi
    export PGS3_RUN_DIR="${repo_dir}/artifacts/acceptance/${run_id}"
    export PGS3_EVIDENCE_TMP
    PGS3_EVIDENCE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/pgs3-evidence.XXXXXXXX")
    python3 "${evidence_helper}" init \
        --repo "${repo_dir}" \
        --run-dir "${PGS3_RUN_DIR}" \
        --suite "${suite}" \
        --pg-major "${pg_major}"
    printf 'acceptance evidence: %s\n' "${PGS3_RUN_DIR}"
}

evidence_run() {
    local name=$1
    shift
    local started finished status rc command command_file redacted_command output raw
    started=$(evidence_utc)
    command=$(evidence_quote_command "$@")
    command_file=$(mktemp "${PGS3_EVIDENCE_TMP}/command.XXXXXXXX")
    chmod 600 "${command_file}"
    printf '%s' "${command}" >"${command_file}"
    redacted_command=$(printf '%s' "${command}" | python3 "${evidence_helper}" redact)
    raw=$(mktemp "${PGS3_EVIDENCE_TMP}/raw.XXXXXXXX")
    output="steps/$(printf '%03d' "$((PGS3_EVIDENCE_STEP + 1))")-$(printf '%s' "${name}" | tr -cs 'A-Za-z0-9._-' '-').log"
    PGS3_EVIDENCE_STEP=$((PGS3_EVIDENCE_STEP + 1))

    printf '+ %s\n' "${redacted_command}"

    # A shell function used directly as an `if`/`||` condition runs with
    # errexit disabled throughout its body.  Invoke evidence_run only as a
    # simple command (use evidence_try when the caller must continue).  The ERR
    # trap stops a stateful step at its first unhandled failed assertion, while
    # returning here so the failure can still be recorded.
    local caller_options=$- previous_err_trap step_rc=0 evidence_step_pid=$BASHPID
    previous_err_trap=$(trap -p ERR || true)
    trap 'rc=$?; if [[ $BASHPID != $evidence_step_pid ]]; then trap - ERR; return "$rc"; fi; step_rc=$rc; return 0' ERR
    set -Ee
    _evidence_execute_step "$@" >"${raw}" 2>&1
    trap - ERR
    if [[ -n ${previous_err_trap} ]]; then
        eval "${previous_err_trap}"
    fi
    set +e
    rc=${step_rc}
    if ((rc == 0)); then
        status=PASS
    else
        status=FAIL
    fi
    python3 "${evidence_helper}" redact <"${raw}" >"${PGS3_RUN_DIR}/${output}"
    rm -f -- "${raw}"
    cat "${PGS3_RUN_DIR}/${output}"
    finished=$(evidence_utc)
    python3 "${evidence_helper}" record \
        --run-dir "${PGS3_RUN_DIR}" \
        --name "${name}" \
        --status "${status}" \
        --exit-status "${rc}" \
        --started-at "${started}" \
        --finished-at "${finished}" \
        --command-file "${command_file}" \
        --output "${output}"
    rm -f -- "${command_file}"
    if [[ ${caller_options} != *E* ]]; then
        set +E
    fi
    if [[ ${caller_options} == *e* ]]; then
        set -e
    fi
    return "${rc}"
}

# Run and record a step without aborting the suite.  The result is returned in
# PGS3_EVIDENCE_LAST_RC so callers never put evidence_run itself in a shell
# conditional and accidentally weaken assertion handling.
evidence_try() {
    local caller_options=$-
    set +e
    evidence_run "$@"
    PGS3_EVIDENCE_LAST_RC=$?
    if [[ ${caller_options} == *e* ]]; then
        set -e
    fi
    return 0
}

evidence_blocked() {
    local name=$1 reason=$2
    local started finished output
    started=$(evidence_utc)
    output="steps/$(printf '%03d' "$((PGS3_EVIDENCE_STEP + 1))")-$(printf '%s' "${name}" | tr -cs 'A-Za-z0-9._-' '-').log"
    PGS3_EVIDENCE_STEP=$((PGS3_EVIDENCE_STEP + 1))
    printf 'BLOCKED: %s\n' "${reason}" | python3 "${evidence_helper}" redact \
        >"${PGS3_RUN_DIR}/${output}"
    cat "${PGS3_RUN_DIR}/${output}"
    finished=$(evidence_utc)
    python3 "${evidence_helper}" record \
        --run-dir "${PGS3_RUN_DIR}" \
        --name "${name}" \
        --status BLOCKED \
        --exit-status 125 \
        --started-at "${started}" \
        --finished-at "${finished}" \
        --command "preflight ${name}" \
        --output "${output}"
}

evidence_finalize() {
    local result=$1
    python3 "${evidence_helper}" finalize \
        --run-dir "${PGS3_RUN_DIR}" \
        --result "${result}"
}

evidence_cleanup() {
    if [[ -n ${PGS3_EVIDENCE_TMP:-} && -d ${PGS3_EVIDENCE_TMP} ]]; then
        rm -rf -- "${PGS3_EVIDENCE_TMP}"
    fi
}

PGS3_EVIDENCE_STEP=0
# shellcheck disable=SC2034 # read by callers after evidence_try
PGS3_EVIDENCE_LAST_RC=0
