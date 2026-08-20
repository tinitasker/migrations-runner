#!/bin/sh
set -eu

project_directory=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
postgres_image=${POSTGRES_IMAGE:-postgres:18}
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/tinitasker-postgres-integration.XXXXXX")
test_id=${temporary_directory##*.}
runner_image="tinitasker/migrations-runner:integration-$test_id"
database_container="tinitasker-migrations-db-$test_id"
database_network="tinitasker-migrations-$test_id"
certificate_volume="tinitasker-migrations-certs-$test_id"

database_name=tinitasker_integration
database_user=migrations
database_password=tinitasker-integration-password
migration_commit_sha=0123456789abcdef0123456789abcdef01234567

cleanup() {
  set +e
  docker container rm --force "$database_container" >/dev/null 2>&1
  docker network rm "$database_network" >/dev/null 2>&1
  docker volume rm "$certificate_volume" >/dev/null 2>&1
  docker image rm "$runner_image" >/dev/null 2>&1
  rm -rf "$temporary_directory"
}

trap cleanup 0 HUP INT TERM

fail() {
  printf 'postgres-integration: %s\n' "$*" >&2
  exit 1
}

assert_query() {
  expected=$1
  query=$2
  description=$3

  actual=$(docker exec \
    --env "PGPASSWORD=$database_password" \
    "$database_container" \
    psql \
      --no-psqlrc \
      --quiet \
      --tuples-only \
      --no-align \
      --set=ON_ERROR_STOP=1 \
      --username="$database_user" \
      --dbname="$database_name" \
      --command "$query") \
    || fail "could not verify $description"

  [ "$actual" = "$expected" ] \
    || fail "$description: expected '$expected', received '$actual'"
}

package_bundle() {
  source_directory=$1
  output_directory=$2

  docker run --rm \
    --pull=never \
    --read-only \
    --cap-drop=all \
    --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$source_directory,dst=/source/db,readonly" \
    --mount "type=bind,src=$temporary_directory,dst=/output" \
    --entrypoint /usr/local/bin/package-migrations \
    "$runner_image" \
    /source/db \
    "/output/$output_directory" \
    api \
    public \
    staging \
    tinitasker/api \
    "$migration_commit_sha"
}

run_bundle() {
  bundle_directory=$1
  output_file=$2

  docker run --rm \
    --pull=never \
    --network "$database_network" \
    --read-only \
    --cap-drop=all \
    --security-opt=no-new-privileges \
    --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
    --mount "type=bind,src=$bundle_directory,dst=/migrations,readonly" \
    --env ASPNETCORE_ENVIRONMENT=Staging \
    --env MIGRATION_SERVICE=api \
    --env MIGRATION_SCHEMA=public \
    --env "MIGRATION_COMMIT_SHA=$migration_commit_sha" \
    --env "PGHOST=$database_container" \
    --env PGPORT=5432 \
    --env "PGDATABASE=$database_name" \
    --env "PGUSER=$database_user" \
    --env "PGPASSWORD=$database_password" \
    --env PGSSLMODE=require \
    "$runner_image" > "$output_file" 2>&1
}

command -v docker >/dev/null 2>&1 \
  || fail 'Docker is required'

docker info >/dev/null 2>&1 \
  || fail 'the Docker daemon is unavailable'

docker build --tag "$runner_image" "$project_directory"
docker network create "$database_network" >/dev/null
docker volume create "$certificate_volume" >/dev/null

# The official PostgreSQL image contains OpenSSL. Generate a short-lived key in
# a Docker volume so PostgreSQL owns it with the strict permissions it requires.
docker run --rm \
  --volume "$certificate_volume:/certificates" \
  "$postgres_image" \
  sh -eu -c '
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
      -subj "/CN=postgres" \
      -keyout /certificates/server.key \
      -out /certificates/server.crt >/dev/null 2>&1
    chown postgres:postgres /certificates/server.key /certificates/server.crt
    chmod 0600 /certificates/server.key
    chmod 0644 /certificates/server.crt
  '

docker run --detach \
  --name "$database_container" \
  --network "$database_network" \
  --env "POSTGRES_DB=$database_name" \
  --env "POSTGRES_USER=$database_user" \
  --env "POSTGRES_PASSWORD=$database_password" \
  --volume "$certificate_volume:/certificates:ro" \
  "$postgres_image" \
  postgres \
    -c ssl=on \
    -c ssl_cert_file=/certificates/server.crt \
    -c ssl_key_file=/certificates/server.key >/dev/null

database_ready=false
attempt=1
while [ "$attempt" -le 60 ]; do
  if docker exec "$database_container" \
    pg_isready --quiet --username="$database_user" --dbname="$database_name"; then
    database_ready=true
    break
  fi
  sleep 1
  attempt=$((attempt + 1))
done

if [ "$database_ready" != true ]; then
  docker logs "$database_container" >&2
  fail 'PostgreSQL did not become ready within 60 seconds'
fi

server_major=$(docker exec \
  --env "PGPASSWORD=$database_password" \
  "$database_container" \
  psql \
    --no-psqlrc \
    --quiet \
    --tuples-only \
    --no-align \
    --set=ON_ERROR_STOP=1 \
    --username="$database_user" \
    --dbname="$database_name" \
    --command "SELECT current_setting('server_version_num')::integer / 10000;")
[ "$server_major" = 18 ] \
  || fail "expected PostgreSQL 18, received major version $server_major"

source_directory="$temporary_directory/source-db"
mkdir "$source_directory"

cat > "$source_directory/00000000__baseline.sql" <<'SQL'
do $migration$
begin
  if not exists (
    select 1
    from pg_stat_ssl
    where pid = pg_backend_pid() and ssl
  ) then
    raise exception 'migration connection is not using TLS';
  end if;
end
$migration$;

create table "public"."integration_events" (
  "id" integer not null primary key,
  "description" text not null
);
SQL

cat > "$source_directory/00000002__transactional.sql" <<'SQL'
start transaction;

insert into "public"."integration_events" ("id", "description")
values (1, 'transaction controlled by migration');

commit;
SQL

cat > "$source_directory/00000003__nontransactional.sql" <<'SQL'
insert into "public"."integration_events" ("id", "description")
values (2, 'statement controlled by migration');
SQL

printf '%s\n' 'this dump must never enter the artifact' \
  > "$source_directory/dump.sql"

package_bundle "$source_directory" migration-bundle
bundle_directory="$temporary_directory/migration-bundle"

[ ! -e "$bundle_directory/db/dump.sql" ] \
  || fail 'dump.sql was included in the migration artifact'
[ "$(wc -l < "$bundle_directory/manifest" | tr -d '[:space:]')" = 3 ] \
  || fail 'the migration artifact did not contain exactly three migrations'

first_output="$temporary_directory/first-run.log"
if ! run_bundle "$bundle_directory" "$first_output"; then
  sed -n '1,200p' "$first_output" >&2
  fail 'the first migration run failed'
fi

assert_query 3 \
  'select count(*) from "public"."__migrations";' \
  'initial migration journal count'
assert_query 2 \
  'select count(*) from "public"."integration_events";' \
  'initial migrated row count'

second_output="$temporary_directory/second-run.log"
if ! run_bundle "$bundle_directory" "$second_output"; then
  sed -n '1,200p' "$second_output" >&2
  fail 'the repeated migration run failed'
fi

for migration_stem in \
  00000000__baseline \
  00000002__transactional \
  00000003__nontransactional; do
  grep -F "\"message\":\"Skipping migration $migration_stem\"" "$second_output" >/dev/null \
    || fail "the repeated run did not skip $migration_stem"
done

assert_query 3 \
  'select count(*) from "public"."__migrations";' \
  'repeated migration journal count'
assert_query 2 \
  'select count(*) from "public"."integration_events";' \
  'repeated migrated row count'

cat > "$source_directory/00000005__failing.sql" <<'SQL'
create table "public"."uncommitted_by_runner" ("id" integer);

select 1 / 0;
SQL

package_bundle "$source_directory" failing-bundle
failing_bundle="$temporary_directory/failing-bundle"
failing_output="$temporary_directory/failing-run.log"

if run_bundle "$failing_bundle" "$failing_output"; then
  fail 'a failing migration returned success'
fi

grep -F '"event":"migration.failed"' "$failing_output" >/dev/null \
  || fail 'the failed migration did not emit a structured failure event'
assert_query 0 \
  "select count(*) from \"public\".\"__migrations\" where \"name\" = '00000005__failing';" \
  'failed migration journal count'
assert_query t \
  "select to_regclass('public.uncommitted_by_runner') is not null;" \
  'nontransactional partial side effect'

printf '%s\n' 'postgres-integration: PostgreSQL 18 apply, skip, TLS, transaction, and failure checks passed'
