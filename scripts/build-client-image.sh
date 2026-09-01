#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image=${PGS3_CLIENT_IMAGE:-pgs3-client-test:20250226}
docker_buildkit=${DOCKER_BUILDKIT:-0}
target_arch=${TARGETARCH:-$(docker info --format '{{.Architecture}}')}
case ${target_arch} in
    arm64|aarch64) target_arch=arm64 ;;
    amd64|x86_64) target_arch=amd64 ;;
    *) printf 'unsupported Docker server architecture: %s\n' "${target_arch}" >&2; exit 2 ;;
esac

DOCKER_BUILDKIT="${docker_buildkit}" docker build \
    --build-arg "TARGETARCH=${target_arch}" \
    --tag "${image}" \
    --file "${repo_dir}/docker/client.Dockerfile" \
    "${repo_dir}"
docker image inspect "${image}" \
    --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
