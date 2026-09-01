#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly commit=5522d1c351f75bc00ae0f64f742f3f095f5939d9
image=${PGS3_CEPH_IMAGE:-pgs3-ceph-s3tests:${commit:0:12}}
docker_buildkit=${DOCKER_BUILDKIT:-0}

DOCKER_BUILDKIT="${docker_buildkit}" docker build \
    --build-arg "S3TESTS_COMMIT=${commit}" \
    --file "${repo_dir}/docker/ceph-client.Dockerfile" \
    --tag "${image}" \
    "${repo_dir}"

revision=$(docker image inspect "${image}" \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
if [[ ${revision} != "${commit}" ]]; then
    printf 'Ceph client image revision mismatch: expected %s, got %s\n' \
        "${commit}" "${revision}" >&2
    exit 1
fi
docker image inspect "${image}" \
    --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}} revision={{index .Config.Labels "org.opencontainers.image.revision"}}'
PGS3_CEPH_IMAGE="${image}" "${repo_dir}/tests/ceph/collect-only.sh"
