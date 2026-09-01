#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ceph_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_dir=$(cd -- "${ceph_dir}/../.." && pwd)
readonly commit=5522d1c351f75bc00ae0f64f742f3f095f5939d9
image=${PGS3_CEPH_IMAGE:-pgs3-ceph-s3tests:${commit:0:12}}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/pgs3-ceph-collect.XXXXXXXX")

cleanup() {
    case ${temporary} in
        "${TMPDIR:-/tmp}"/pgs3-ceph-collect.*) rm -rf -- "${temporary}" ;;
        *) printf 'refusing to remove unexpected temporary path: %s\n' "${temporary}" >&2 ;;
    esac
}
trap cleanup EXIT INT TERM

PGS3_ACCESS_KEY_A=static-access-a \
PGS3_SECRET_A=static-secret-a \
PGS3_ACCESS_KEY_B=static-access-b \
PGS3_SECRET_B=static-secret-b \
python3 "${ceph_dir}/write_config.py" \
    --host pgs3-static.invalid \
    --port 9000 \
    --bucket-stem pgs3-static \
    --output "${temporary}/s3tests.conf"

docker run --rm \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=${ceph_dir},dst=/pgs3-ceph-harness,readonly" \
    --env BOTO_DISABLE_CRT=true \
    --env PYTHONPATH=/pgs3-ceph-harness \
    "${image}" \
    python /pgs3-ceph-harness/adapter_selftest.py

docker run --rm \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=${repo_dir},dst=/repo,readonly" \
    --mount "type=bind,src=${temporary},dst=/results" \
    "${image}" \
    python /repo/tests/ceph/selection.py materialize \
        --selection /repo/tests/ceph/selection.json \
        --upstream /opt/s3-tests \
        --output /results/suite-manifest.json \
        --nodeids /results/selected-nodeids.txt

mapfile -t nodeids <"${temporary}/selected-nodeids.txt"
collection_status=0
docker run --rm \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=${temporary}/s3tests.conf,dst=/run/pgs3/s3tests.conf,readonly" \
    --mount "type=bind,src=${repo_dir}/tests/ceph,dst=/pgs3-ceph-harness,readonly" \
    --env BOTO_DISABLE_CRT=true \
    --env PYTHONPATH=/pgs3-ceph-harness \
    --env S3TEST_CONF=/run/pgs3/s3tests.conf \
    "${image}" \
    pytest --collect-only -q -p no:cacheprovider -p pgs3_adapter "${nodeids[@]}" \
    >"${temporary}/collection.txt" 2>&1 || collection_status=$?
if ((collection_status)); then
    sed -n '1,240p' "${temporary}/collection.txt" >&2
    exit "${collection_status}"
fi

docker run --rm \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=${repo_dir},dst=/repo,readonly" \
    --mount "type=bind,src=${temporary},dst=/results" \
    "${image}" \
    python /repo/tests/ceph/selection.py verify-collection \
        --selection /repo/tests/ceph/selection.json \
        --upstream /opt/s3-tests \
        --collection /results/collection.txt \
        --output /results/collection.json
