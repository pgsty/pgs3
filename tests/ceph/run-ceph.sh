#!/usr/bin/env bash
set -Eeuo pipefail

ceph_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${ceph_dir}/../.." && pwd)
# shellcheck disable=SC1091 # resolved relative to this script
source "${repo_dir}/tests/integration/harness_lib.sh"

pg_major=${PG_MAJOR:-17}
skip_server_build=${PGS3_SKIP_BUILD:-0}
skip_ceph_build=${PGS3_SKIP_CEPH_BUILD:-0}
suite_timeout=${PGS3_CEPH_TIMEOUT_SECONDS:-3600}
requested_run_id=''
readonly ceph_commit=5522d1c351f75bc00ae0f64f742f3f095f5939d9
ceph_image=${PGS3_CEPH_IMAGE:-pgs3-ceph-s3tests:${ceph_commit:0:12}}

usage() {
    printf '%s\n' \
        'usage: run-ceph.sh [--pg 17|18] [--skip-server-build]' \
        '                   [--skip-ceph-build] [--run-id ID]' \
        '' \
        'Runs the explicit Phase 1 Ceph s3-tests selection.  A PASS requires' \
        'at least 150 actually executed and passed cases, no selected failure,' \
        'error, skip, or missing result, and exact upstream collection.'
}

while (($#)); do
    case $1 in
        --pg)
            pg_major=${2:?--pg requires a value}
            shift 2
            ;;
        --skip-server-build)
            skip_server_build=1
            shift
            ;;
        --skip-ceph-build)
            skip_ceph_build=1
            shift
            ;;
        --run-id)
            requested_run_id=${2:?--run-id requires a value}
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case ${pg_major} in
    17|18) ;;
    *) printf 'unsupported PostgreSQL major: %s\n' "${pg_major}" >&2; exit 2 ;;
esac
case ${skip_server_build}:${skip_ceph_build} in
    [01]:[01]) ;;
    *) printf 'skip-build settings must be 0 or 1\n' >&2; exit 2 ;;
esac
if [[ ! ${suite_timeout} =~ ^[1-9][0-9]*$ ]]; then
    printf 'PGS3_CEPH_TIMEOUT_SECONDS must be a positive integer\n' >&2
    exit 2
fi

evidence_init "${repo_dir}" ceph-s3-tests "${pg_major}" "${requested_run_id}"
trap harness_cleanup EXIT INT TERM

harness_require_command docker
harness_require_command python3
harness_require_command timeout
evidence_run ceph-python-compile python3 -m py_compile \
    "${ceph_dir}/selection.py" \
    "${ceph_dir}/summarize.py" \
    "${ceph_dir}/write_config.py" \
    "${ceph_dir}/pgs3_adapter.py" \
    "${ceph_dir}/adapter_selftest.py" \
    "${ceph_dir}/test_harness.py"
evidence_run ceph-shell-syntax bash -n \
    "${repo_dir}/scripts/build-ceph-image.sh" \
    "${ceph_dir}/container_run.sh" \
    "${ceph_dir}/run-ceph.sh"
evidence_run ceph-offline-tests python3 -m unittest "${ceph_dir}/test_harness.py"

if ((skip_ceph_build)); then
    evidence_run ceph-image-inspect docker image inspect "${ceph_image}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}} revision={{index .Config.Labels "org.opencontainers.image.revision"}}'
else
    evidence_run ceph-image-build "${repo_dir}/scripts/build-ceph-image.sh"
fi
revision=$(docker image inspect "${ceph_image}" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
if [[ ${revision} != "${ceph_commit}" ]]; then
    printf 'Ceph image revision mismatch: expected %s, got %s\n' \
        "${ceph_commit}" "${revision}" >&2
    exit 1
fi
evidence_run ceph-client-versions docker run --rm "${ceph_image}" \
    python -c 'import boto3,botocore,pytest; print("boto3="+boto3.__version__); print("botocore="+botocore.__version__); print("pytest="+pytest.__version__)'

mkdir -p "${PGS3_RUN_DIR}/ceph"
evidence_run ceph-selection-materialize docker run --rm \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=${repo_dir},dst=/repo,readonly" \
    --mount "type=bind,src=${PGS3_RUN_DIR}/ceph,dst=/results" \
    "${ceph_image}" \
    python /repo/tests/ceph/selection.py materialize \
        --selection /repo/tests/ceph/selection.json \
        --upstream /opt/s3-tests \
        --output /results/suite-manifest.json \
        --nodeids /results/selected-nodeids.txt

harness_start_server "${pg_major}" "${skip_server_build}"
suffix=$(printf '%s' "${PGS3_RUN_DIR}" | sha256sum | cut -c1-10)
config_file="${harness_work_dir}/s3tests.conf"
evidence_run ceph-config-write python3 "${ceph_dir}/write_config.py" \
    --host "${harness_alias}" \
    --port 9000 \
    --bucket-stem "pgs3-${suffix}" \
    --output "${config_file}"

ceph_failed=0
evidence_try ceph-s3-tests timeout --foreground "${suite_timeout}s" \
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --network "${harness_network}" \
        --mount "type=bind,src=${repo_dir},dst=/repo,readonly" \
        --mount "type=bind,src=${PGS3_RUN_DIR}/ceph,dst=/results" \
        --mount "type=bind,src=${config_file},dst=/run/pgs3/s3tests.conf,readonly" \
        --env AWS_MAX_ATTEMPTS=2 \
        --env AWS_RETRY_MODE=standard \
        --env PG_MAJOR="${pg_major}" \
        --env PGS3_ACCESS_KEY_A \
        --env PGS3_ACCESS_KEY_B \
        --env PGS3_SECRET_A \
        --env PGS3_SECRET_B \
        --env S3TEST_CONF=/run/pgs3/s3tests.conf \
        "${ceph_image}" \
        bash /repo/tests/ceph/container_run.sh
ceph_failed=${PGS3_EVIDENCE_LAST_RC}

if [[ ! -s ${PGS3_RUN_DIR}/ceph/junit.xml ]]; then
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<testsuites><testsuite name="ceph-s3-tests-harness" tests="0" errors="1"><system-err>container stopped before JUnit publication</system-err></testsuite></testsuites>' \
        >"${PGS3_RUN_DIR}/ceph/junit.xml"
fi
if [[ ! -s ${PGS3_RUN_DIR}/ceph/collection.json ]]; then
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --mount "type=bind,src=${repo_dir},dst=/repo,readonly" \
        --mount "type=bind,src=${PGS3_RUN_DIR}/ceph,dst=/results" \
        "${ceph_image}" \
        python /repo/tests/ceph/selection.py verify-collection \
            --selection /repo/tests/ceph/selection.json \
            --upstream /opt/s3-tests \
            --collection /dev/null \
            --output /results/collection.json || true
fi
if [[ ! -s ${PGS3_RUN_DIR}/ceph/results.json ]]; then
    python3 "${ceph_dir}/summarize.py" \
        --manifest "${PGS3_RUN_DIR}/ceph/suite-manifest.json" \
        --junit "${PGS3_RUN_DIR}/ceph/junit.xml" \
        --output "${PGS3_RUN_DIR}/ceph/results.json" \
        --summary "${PGS3_RUN_DIR}/ceph/summary.txt" \
        --pg-major "${pg_major}" \
        --pytest-exit-status "${ceph_failed:-1}" \
        --harness-error 'container stopped before publishing results.json' || true
fi

evidence_run ceph-result-files sha256sum \
    "${PGS3_RUN_DIR}/ceph/suite-manifest.json" \
    "${PGS3_RUN_DIR}/ceph/collection.json" \
    "${PGS3_RUN_DIR}/ceph/junit.xml" \
    "${PGS3_RUN_DIR}/ceph/results.json"
cat "${PGS3_RUN_DIR}/ceph/summary.txt"

if ((ceph_failed)); then
    export harness_result=FAIL
    exit 1
fi
export harness_result=PASS
