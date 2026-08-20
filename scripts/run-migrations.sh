#!/bin/sh
set -eu

export LC_ALL=C

migrations_directory=${MIGRATIONS_DIRECTORY:-/migrations}
validator=${MIGRATION_VALIDATOR:-/usr/local/bin/validate-migration-bundle}

bootstrap_fail() {
  printf 'migration-runner: %s\n' "$*" >&2
  exit 1
}

migration_service=${MIGRATION_SERVICE:-}
case "$migration_service" in
  api) expected_schema=public ;;
  identity) expected_schema=identity ;;
  messaging) expected_schema=messaging ;;
  storage) expected_schema=storage ;;
  *) bootstrap_fail 'MIGRATION_SERVICE must be api, identity, messaging, or storage' ;;
esac

migration_schema=${MIGRATION_SCHEMA:-}
[ "$migration_schema" = "$expected_schema" ] \
  || bootstrap_fail "MIGRATION_SCHEMA must be $expected_schema for $migration_service"

case "${ASPNETCORE_ENVIRONMENT:-}" in
  Staging|staging) migration_environment=staging ;;
  Production|production) migration_environment=production ;;
  *) bootstrap_fail 'ASPNETCORE_ENVIRONMENT must be Staging or Production' ;;
esac

migration_commit_sha=${MIGRATION_COMMIT_SHA:-}
printf '%s\n' "$migration_commit_sha" | grep -Eq '^[0-9a-f]{40}$' \
  || bootstrap_fail 'MIGRATION_COMMIT_SHA must be a lowercase 40-character Git commit SHA'

log_json() {
  level=$1
  event=$2
  message=$3
  printf '{"env":"%s","service":"%s","level":"%s","event":"%s","message":"%s","repository":"%s","commit_sha":"%s"}\n' \
    "$migration_environment" "$migration_service" "$level" "$event" "$message" \
    "${metadata_repository:-unknown}" "${metadata_commit_sha:-unknown}"
}

fail() {
  log_json 'Error' 'migration.failed' "$*" >&2
  exit 1
}

[ -x "$validator" ] || fail 'Migration bundle validator is unavailable'
if ! "$validator" "$migrations_directory"; then
  fail 'Migration bundle validation failed'
fi

metadata_service=
metadata_schema=
metadata_environment=
metadata_repository=
metadata_commit_sha=
while IFS= read -r metadata_line || [ -n "$metadata_line" ]; do
  metadata_key=${metadata_line%%=*}
  metadata_value=${metadata_line#*=}
  case "$metadata_key" in
    SERVICE) metadata_service=$metadata_value ;;
    SCHEMA) metadata_schema=$metadata_value ;;
    ENVIRONMENT) metadata_environment=$metadata_value ;;
    REPOSITORY) metadata_repository=$metadata_value ;;
    COMMIT_SHA) metadata_commit_sha=$metadata_value ;;
  esac
done < "$migrations_directory/metadata.env"

[ "$metadata_service" = "$migration_service" ] \
  || fail 'Bundle SERVICE does not match MIGRATION_SERVICE'
[ "$metadata_schema" = "$migration_schema" ] \
  || fail 'Bundle SCHEMA does not match MIGRATION_SCHEMA'
[ "$metadata_environment" = "$migration_environment" ] \
  || fail 'Bundle ENVIRONMENT does not match ASPNETCORE_ENVIRONMENT'
[ "$metadata_repository" = "tinitasker/$migration_service" ] \
  || fail 'Bundle REPOSITORY does not match MIGRATION_SERVICE'
[ "$metadata_commit_sha" = "$migration_commit_sha" ] \
  || fail 'Bundle COMMIT_SHA does not match MIGRATION_COMMIT_SHA'

[ -n "${PGHOST:-}" ] || fail 'PGHOST is required'
[ -n "${PGPORT:-}" ] || fail 'PGPORT is required'
[ -n "${PGDATABASE:-}" ] || fail 'PGDATABASE is required'
[ -n "${PGUSER:-}" ] || fail 'PGUSER is required'
[ -n "${PGPASSWORD:-}" ] || fail 'PGPASSWORD is required'
[ "${PGSSLMODE:-}" = 'require' ] || fail 'PGSSLMODE must be require'

case "$PGPORT" in
  ''|*[!0-9]*) fail 'PGPORT must be numeric' ;;
esac

normalized_pgport=$(printf '%s\n' "$PGPORT" | sed 's/^0*//')
[ -n "$normalized_pgport" ] || normalized_pgport=0
case "$normalized_pgport" in
  ??????*) fail 'PGPORT must be between 1 and 65535' ;;
esac
if [ "$normalized_pgport" -lt 1 ] || [ "$normalized_pgport" -gt 65535 ]; then
  fail 'PGPORT must be between 1 and 65535'
fi

run_psql() {
  psql --no-psqlrc --quiet --set=ON_ERROR_STOP=1 --dbname="$PGDATABASE" "$@"
}

log_json 'Information' 'migration.started' 'Validating migration history and applying pending migrations'

if ! run_psql --command "CREATE SCHEMA IF NOT EXISTS \"$migration_schema\"; CREATE TABLE IF NOT EXISTS \"$migration_schema\".\"__migrations\" (\"name\" varchar(256) NOT NULL PRIMARY KEY);" >/dev/null; then
  fail 'Could not initialize the migration history table'
fi

applied_count=0
skipped_count=0
while IFS= read -r migration_name || [ -n "$migration_name" ]; do
  migration_stem=${migration_name%.sql}

  if ! migration_applied=$(run_psql --tuples-only --no-align \
    --command "SELECT EXISTS (SELECT 1 FROM \"$migration_schema\".\"__migrations\" WHERE \"name\" = '$migration_stem');"); then
    fail "Could not check migration $migration_stem"
  fi

  case "$migration_applied" in
    t)
      log_json 'Information' 'migration.skipped' "Skipping migration $migration_stem"
      skipped_count=$((skipped_count + 1))
      continue
      ;;
    f) ;;
    *) fail "Unexpected history result for migration $migration_stem" ;;
  esac

  log_json 'Information' 'migration.applying' "Applying migration $migration_stem"

  # Deliberately do not add --single-transaction or issue BEGIN/COMMIT here.
  # Every migration controls its own transaction boundaries.
  if ! run_psql --file="$migrations_directory/db/$migration_name" >/dev/null; then
    fail "Migration failed: $migration_stem"
  fi

  if ! run_psql --command "INSERT INTO \"$migration_schema\".\"__migrations\" (\"name\") VALUES ('$migration_stem');" >/dev/null; then
    fail "Could not record migration $migration_stem"
  fi

  log_json 'Information' 'migration.applied' "Applied migration $migration_stem"
  applied_count=$((applied_count + 1))
done < "$migrations_directory/manifest"

log_json 'Information' 'migration.completed' "Database migrations completed: applied=$applied_count skipped=$skipped_count"
