#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly repo_dir=/repo
readonly upstream_dir=/opt/s3-tests
readonly results_dir=/results
readonly selection_file=${repo_dir}/tests/ceph/selection.json
readonly evidence_helper=${repo_dir}/scripts/lib/evidence.py
readonly pg_major=${PG_MAJOR:?PG_MAJOR is required}
readonly config_file=${S3TEST_CONF:?S3TEST_CONF is required}
export PYTHONPATH="${repo_dir}/tests/ceph${PYTHONPATH:+:${PYTHONPATH}}"
# awscrt rejects the pinned negative-expiry fixture before it can send a
# request.  Keep botocore's pure-Python SigV4 signer for this suite so the
# selected security case reaches the endpoint; the explicit CRC64NVME values
# in the checksum cases do not require CRT-side checksum calculation.
export BOTO_DISABLE_CRT=true

mkdir -p "${results_dir}"
python "${repo_dir}/tests/ceph/selection.py" materialize \
    --selection "${selection_file}" \
    --upstream "${upstream_dir}" \
    --output "${results_dir}/suite-manifest.json" \
    --nodeids "${results_dir}/selected-nodeids.txt"
mapfile -t nodeids <"${results_dir}/selected-nodeids.txt"
if ((${#nodeids[@]} < 150)); then
    printf 'selection unexpectedly contains only %d cases\n' "${#nodeids[@]}" >&2
    exit 2
fi

cd "${upstream_dir}"
collection_raw=$(mktemp /tmp/pgs3-ceph-collection.XXXXXXXX)
junit_raw=$(mktemp /tmp/pgs3-ceph-junit.XXXXXXXX)
cleanup_raw() {
    rm -f -- "${collection_raw}" "${junit_raw}"
}
trap cleanup_raw EXIT INT TERM

set +e
pytest --collect-only -q -p no:cacheprovider -p pgs3_adapter "${nodeids[@]}" \
    >"${collection_raw}" 2>&1
collection_status=$?
set -e
python "${evidence_helper}" redact <"${collection_raw}" \
    >"${results_dir}/collection.txt"

verification_status=0
python "${repo_dir}/tests/ceph/selection.py" verify-collection \
    --selection "${selection_file}" \
    --upstream "${upstream_dir}" \
    --collection "${collection_raw}" \
    --output "${results_dir}/collection.json" || verification_status=$?
if ((collection_status != 0)); then
    verification_status=${collection_status}
fi

if ((verification_status != 0)); then
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<testsuites><testsuite name="ceph-s3-tests-collection" tests="0" errors="1"><system-err>collection failed; see collection.txt</system-err></testsuite></testsuites>' \
        >"${results_dir}/junit.xml"
    python "${repo_dir}/tests/ceph/summarize.py" \
        --manifest "${results_dir}/suite-manifest.json" \
        --junit "${results_dir}/junit.xml" \
        --output "${results_dir}/results.json" \
        --summary "${results_dir}/summary.txt" \
        --pg-major "${pg_major}" \
        --pytest-exit-status "${verification_status}" \
        --harness-error "pytest collection or exact-node verification failed"
    exit 1
fi

set +e
pytest -ra -q -p no:cacheprovider -p pgs3_adapter \
    --junitxml="${junit_raw}" \
    "${nodeids[@]}"
pytest_status=$?
set -e

# The raw report lives only in the container's /tmp.  The mounted evidence
# directory receives the credential-redacted copy and the derived JSON.
python "${evidence_helper}" redact <"${junit_raw}" \
    >"${results_dir}/junit.xml"

summary_status=0
python "${repo_dir}/tests/ceph/summarize.py" \
    --manifest "${results_dir}/suite-manifest.json" \
    --junit "${results_dir}/junit.xml" \
    --output "${results_dir}/results.json" \
    --summary "${results_dir}/summary.txt" \
    --pg-major "${pg_major}" \
    --pytest-exit-status "${pytest_status}" || summary_status=$?

if ((pytest_status != 0 || summary_status != 0)); then
    exit 1
fi
