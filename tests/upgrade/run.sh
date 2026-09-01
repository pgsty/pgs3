#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091 # repository-local evidence helper
source "${repo_dir}/scripts/lib/evidence.sh"

pg_major=${PG_MAJOR:-17}
image=${PGS3_TEST_IMAGE:-"pgs3-test:pg${pg_major}"}
skip_build=${PGS3_SKIP_BUILD:-0}
docker_buildkit=${DOCKER_BUILDKIT:-0}
static_only=0
old_version=0.1.0
new_version=0.1.1
fixture_sha=b4123f4c877cd18879a27073df4301660b5539433d21dc37dce1f72b764c534a
container="pgs3-upgrade-pg${pg_major}-$$"
upgrade_db=pgs3_upgrade_path
semantic_db=pgs3_upgrade_semantic
direct_db=pgs3_direct_install
server_role=pgs3_upgrade_server
UPGRADE_RESULT=RUNNING
UPGRADE_CLEANUP_FAILED=0

while (($#)); do
    case $1 in
        --pg)
            pg_major=$2
            image=${PGS3_TEST_IMAGE:-"pgs3-test:pg${pg_major}"}
            container="pgs3-upgrade-pg${pg_major}-$$"
            shift 2
            ;;
        --static-only)
            static_only=1
            shift
            ;;
        *)
            printf 'unknown upgrade option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
done

case ${pg_major} in
    17|18) ;;
    *) printf 'unsupported PostgreSQL major: %s\n' "${pg_major}" >&2; exit 2 ;;
esac
case ${skip_build} in
    0|1) ;;
    *) printf 'PGS3_SKIP_BUILD must be 0 or 1\n' >&2; exit 2 ;;
esac

upgrade_wait_postgres() {
    local _
    for _ in $(seq 1 60); do
        if docker exec "${container}" \
            pg_isready --username postgres --dbname postgres >/dev/null 2>&1
        then
            docker exec "${container}" \
                pg_isready --username postgres --dbname postgres
            return 0
        fi
        sleep 1
    done
    printf 'PostgreSQL did not become ready in %s\n' "${container}" >&2
    return 1
}

upgrade_check_package() {
    docker exec "${container}" bash -ceu '
        extension_dir=$(pg_config --sharedir)/extension
        test -f "${extension_dir}/pgs3--0.1.1.sql"
        test -f "${extension_dir}/pgs3--0.1.0--0.1.1.sql"
        test ! -e "${extension_dir}/pgs3--0.1.0.sql"
        grep -Fx "default_version = '\''0.1.1'\''" "${extension_dir}/pgs3.control"
        sha256sum "${extension_dir}/pgs3--0.1.1.sql" \
            "${extension_dir}/pgs3--0.1.0--0.1.1.sql"
    '
}

upgrade_copy_baseline() {
    local shared_dir
    shared_dir=$(docker exec "${container}" pg_config --sharedir)
    docker cp \
        "${repo_dir}/tests/fixtures/extension/pgs3--${old_version}.sql" \
        "${container}:${shared_dir}/extension/pgs3--${old_version}.sql"
    docker exec "${container}" bash -ceu '
        extension_dir=$(pg_config --sharedir)/extension
        actual=$(sha256sum "${extension_dir}/pgs3--0.1.0.sql" | cut -d " " -f 1)
        test "${actual}" = "$1"
    ' bash "${fixture_sha}"
}

upgrade_psql() {
    local database=$1
    shift
    docker exec "${container}" psql \
        --username postgres --dbname "${database}" --no-psqlrc \
        --set ON_ERROR_STOP=1 "$@"
}

upgrade_psql_file() {
    local database=$1 sql_file=$2
    docker exec --interactive "${container}" psql \
        --username postgres --dbname "${database}" --no-psqlrc \
        --set ON_ERROR_STOP=1 <"${sql_file}"
}

upgrade_compare_catalogs() {
    diff --unified \
        <(docker exec --interactive "${container}" psql \
            --username postgres --dbname "${upgrade_db}" --no-psqlrc \
            --set ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
            <"${repo_dir}/tests/upgrade/catalog.sql") \
        <(docker exec --interactive "${container}" psql \
            --username postgres --dbname "${direct_db}" --no-psqlrc \
            --set ON_ERROR_STOP=1 --quiet --tuples-only --no-align \
            <"${repo_dir}/tests/upgrade/catalog.sql")
}

upgrade_cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    set +e

    if docker container inspect "${container}" >/dev/null 2>&1; then
        evidence_try upgrade-postgres-logs docker logs "${container}"
        if ((PGS3_EVIDENCE_LAST_RC != 0)); then
            UPGRADE_CLEANUP_FAILED=1
        fi
        evidence_try upgrade-container-remove docker rm --force --volumes "${container}"
        if ((PGS3_EVIDENCE_LAST_RC != 0)); then
            UPGRADE_CLEANUP_FAILED=1
        fi
    fi

    if [[ ${UPGRADE_RESULT} == RUNNING ]]; then
        UPGRADE_RESULT=FAIL
        if ((original_status == 0)); then
            original_status=1
        fi
    fi
    if ((original_status != 0 || UPGRADE_CLEANUP_FAILED != 0)); then
        UPGRADE_RESULT=FAIL
        original_status=1
    fi
    evidence_finalize "${UPGRADE_RESULT}" || original_status=1
    evidence_cleanup
    printf 'Upgrade test result: %s\nmanifest: %s/manifest.json\n' \
        "${UPGRADE_RESULT}" "${PGS3_RUN_DIR}"
    exit "${original_status}"
}

evidence_init "${repo_dir}" extension-upgrade "${pg_major}"
trap upgrade_cleanup EXIT INT TERM

evidence_run upgrade-bash-syntax bash -n "${repo_dir}/tests/upgrade/run.sh"
# shellcheck disable=SC2016 # positional parameters expand in the child shell
evidence_run upgrade-fixture-sha bash -ceu '
    actual=$(sha256sum "$1" | cut -d " " -f 1)
    test "${actual}" = "$2"
' bash \
    "${repo_dir}/tests/fixtures/extension/pgs3--${old_version}.sql" \
    "${fixture_sha}"
evidence_run upgrade-static-contract \
    python3 -m unittest "${repo_dir}/tests/upgrade/test_static.py"

if ((static_only)); then
    UPGRADE_RESULT=PASS
    exit 0
fi

if ((skip_build)); then
    evidence_run upgrade-server-image-inspect docker image inspect "${image}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
else
    evidence_run upgrade-server-image-build env \
        "DOCKER_BUILDKIT=${docker_buildkit}" docker build \
        --build-arg "PG_MAJOR=${pg_major}" \
        --tag "${image}" \
        --file "${repo_dir}/docker/Dockerfile" \
        "${repo_dir}"
    evidence_run upgrade-server-image-inspect docker image inspect "${image}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
fi

evidence_run upgrade-container-start docker run --detach \
    --name "${container}" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    "${image}" \
    postgres \
    -c shared_preload_libraries=pgs3 \
    -c pgs3.enabled=off \
    -c "pgs3.server_role=${server_role}" \
    -c pgs3.inline_threshold=8B \
    -c pgs3.chunk_size=1MB
evidence_run upgrade-postgres-ready upgrade_wait_postgres
evidence_run upgrade-package-contents upgrade_check_package
evidence_run upgrade-copy-frozen-baseline upgrade_copy_baseline

evidence_run upgrade-create-configured-server-role upgrade_psql postgres \
    --command "CREATE ROLE ${server_role} NOLOGIN NOINHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS"

# shellcheck disable=SC2016 # positional parameters expand in the child shell
evidence_run upgrade-create-databases bash -ceu '
    docker exec "$1" createdb --username postgres "$2"
    docker exec "$1" createdb --username postgres "$3"
    docker exec "$1" createdb --username postgres "$4"
' bash "${container}" "${upgrade_db}" "${semantic_db}" "${direct_db}"

evidence_run upgrade-available-path upgrade_psql postgres --command "
DO \$paths\$
BEGIN
    ASSERT EXISTS (
        SELECT 1 FROM pg_catalog.pg_available_extension_versions
         WHERE name = 'pgs3' AND version = '${old_version}'
    );
    ASSERT EXISTS (
        SELECT 1 FROM pg_catalog.pg_available_extension_versions
         WHERE name = 'pgs3' AND version = '${new_version}'
    );
    ASSERT EXISTS (
        SELECT 1 FROM pg_catalog.pg_extension_update_paths('pgs3')
         WHERE source = '${old_version}'
           AND target = '${new_version}'
           AND path IS NOT NULL
    );
END
\$paths\$;"

evidence_run upgrade-install-old upgrade_psql "${upgrade_db}" \
    --command "CREATE EXTENSION pgs3 VERSION '${old_version}'"
evidence_run upgrade-prepare-rich-fixture upgrade_psql_file \
    "${upgrade_db}" "${repo_dir}/tests/upgrade/prepare.sql"
evidence_run upgrade-alter-extension upgrade_psql "${upgrade_db}" \
    --command "ALTER EXTENSION pgs3 UPDATE TO '${new_version}'"
evidence_run upgrade-verify-rich-fixture upgrade_psql_file \
    "${upgrade_db}" "${repo_dir}/tests/upgrade/verify.sql"

evidence_run upgrade-install-old-semantic upgrade_psql "${semantic_db}" \
    --command "CREATE EXTENSION pgs3 VERSION '${old_version}'"
evidence_run upgrade-alter-extension-semantic upgrade_psql "${semantic_db}" \
    --command "ALTER EXTENSION pgs3 UPDATE TO '${new_version}'"
evidence_run upgrade-install-current-direct upgrade_psql "${direct_db}" \
    --command "CREATE EXTENSION pgs3 VERSION '${new_version}'"
evidence_run upgrade-smoke-upgraded upgrade_psql_file \
    "${upgrade_db}" "${repo_dir}/tests/sql/smoke.sql"
evidence_run upgrade-smoke-semantic-upgraded upgrade_psql_file \
    "${semantic_db}" "${repo_dir}/tests/sql/smoke.sql"
evidence_run upgrade-smoke-direct upgrade_psql_file \
    "${direct_db}" "${repo_dir}/tests/sql/smoke.sql"
evidence_run upgrade-semantic-upgraded upgrade_psql_file \
    "${semantic_db}" "${repo_dir}/tests/sql/semantic.sql"
evidence_run upgrade-semantic-direct upgrade_psql_file \
    "${direct_db}" "${repo_dir}/tests/sql/semantic.sql"
evidence_run upgrade-catalog-parity upgrade_compare_catalogs

UPGRADE_RESULT=PASS
