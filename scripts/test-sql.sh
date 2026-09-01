#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091 # repository-local evidence helper
source "${repo_dir}/scripts/lib/evidence.sh"

pg_major=${PG_MAJOR:-17}
image=${PGS3_TEST_IMAGE:-"pgs3-test:pg${pg_major}"}
skip_build=${PGS3_SKIP_BUILD:-0}
container="pgs3-sql-pg${pg_major}-$$"
SQL_RESULT=RUNNING
SQL_CLEANUP_FAILED=0

case ${pg_major} in
    17|18) ;;
    *) printf 'unsupported PostgreSQL major: %s\n' "${pg_major}" >&2; exit 2 ;;
esac
case ${skip_build} in
    0|1) ;;
    *) printf 'PGS3_SKIP_BUILD must be 0 or 1\n' >&2; exit 2 ;;
esac

sql_wait_postgres() {
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

sql_install_extension() {
    docker exec "${container}" \
        psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
        --command 'CREATE EXTENSION pgs3'
}

sql_run_file() {
    local sql_test=$1
    docker exec --interactive "${container}" \
        psql --username postgres --dbname postgres --set ON_ERROR_STOP=1 \
        <"${sql_test}"
}

sql_run_concurrency() {
    docker exec --interactive \
        --env PGS3_TEST_DSN=postgresql://postgres@127.0.0.1/postgres \
        "${container}" bash -s <"${repo_dir}/tests/sql/concurrency.sh"
}

sql_cleanup() {
    local original_status=$?
    trap - EXIT INT TERM
    set +e

    if docker container inspect "${container}" >/dev/null 2>&1; then
        evidence_try sql-postgres-logs docker logs "${container}"
        if ((PGS3_EVIDENCE_LAST_RC != 0)); then
            SQL_CLEANUP_FAILED=1
        fi
        evidence_try sql-container-remove docker rm --force --volumes "${container}"
        if ((PGS3_EVIDENCE_LAST_RC != 0)); then
            SQL_CLEANUP_FAILED=1
        fi
    fi

    if [[ ${SQL_RESULT} == RUNNING ]]; then
        SQL_RESULT=FAIL
        if ((original_status == 0)); then
            original_status=1
        fi
    fi
    if ((original_status != 0 || SQL_CLEANUP_FAILED != 0)); then
        SQL_RESULT=FAIL
        original_status=1
    fi
    evidence_finalize "${SQL_RESULT}" || original_status=1
    evidence_cleanup
    printf 'SQL test result: %s\nmanifest: %s/manifest.json\n' \
        "${SQL_RESULT}" "${PGS3_RUN_DIR}"
    exit "${original_status}"
}

evidence_init "${repo_dir}" sql-semantic "${pg_major}"
trap sql_cleanup EXIT INT TERM

evidence_run sql-bash-syntax bash -n "${repo_dir}/scripts/test-sql.sh"
if command -v shellcheck >/dev/null 2>&1; then
    evidence_run sql-shellcheck shellcheck "${repo_dir}/scripts/test-sql.sh"
fi

if ((skip_build)); then
    evidence_run sql-server-image-inspect docker image inspect "${image}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
else
    evidence_run sql-server-image-build docker build \
        --build-arg "PG_MAJOR=${pg_major}" \
        --tag "${image}" \
        --file "${repo_dir}/docker/Dockerfile" \
        "${repo_dir}"
    evidence_run sql-server-image-inspect docker image inspect "${image}" \
        --format 'image={{index .RepoTags 0}} id={{.Id}} created={{.Created}}'
fi

evidence_run sql-container-start docker run --detach \
    --name "${container}" \
    --env POSTGRES_HOST_AUTH_METHOD=trust \
    "${image}" \
    postgres \
    -c shared_preload_libraries=pgs3 \
    -c pgs3.enabled=off \
    -c pgs3.inline_threshold=8B \
    -c pgs3.chunk_size=1MB
evidence_run sql-postgres-ready sql_wait_postgres
evidence_run sql-extension-install sql_install_extension

mapfile -t sql_tests < <(
    find "${repo_dir}/tests/sql" -maxdepth 1 -type f -name '*.sql' -print | sort
)
if ((${#sql_tests[@]} == 0)); then
    printf 'no SQL tests found under tests/sql\n' >&2
    exit 1
fi

for sql_test in "${sql_tests[@]}"; do
    test_name=$(basename "${sql_test}" .sql | tr -cs 'A-Za-z0-9._-' '-')
    evidence_run "sql-${test_name}" sql_run_file "${sql_test}"
done

if [[ -x "${repo_dir}/tests/sql/concurrency.sh" ]]; then
    evidence_run sql-concurrency-20x50 sql_run_concurrency
fi

SQL_RESULT=PASS
