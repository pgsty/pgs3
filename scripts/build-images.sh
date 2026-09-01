#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
image_prefix=${PGS3_IMAGE_PREFIX:-pgs3-test}
docker_buildkit=${DOCKER_BUILDKIT:-0}

if (($# == 0)); then
    set -- 17 18
fi

for pg_major in "$@"; do
    case ${pg_major} in
        17|18) ;;
        *)
            printf 'unsupported PostgreSQL major: %s (expected 17 or 18)\n' "${pg_major}" >&2
            exit 2
            ;;
    esac
    image="${image_prefix}:pg${pg_major}"
    printf 'building %s from current workspace\n' "${image}"
    DOCKER_BUILDKIT="${docker_buildkit}" docker build \
        --build-arg "PG_MAJOR=${pg_major}" \
        --tag "${image}" \
        --file "${repo_dir}/docker/Dockerfile" \
        "${repo_dir}"
    docker image inspect "${image}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
done
