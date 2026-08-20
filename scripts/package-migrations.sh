#!/bin/sh
set -eu

export LC_ALL=C

fail() {
  printf 'migration-packager: %s\n' "$*" >&2
  exit 1
}

[ "$#" -eq 7 ] || fail 'usage: package-migrations <db-directory> <output-directory> <service> <schema> <environment> <repository> <commit-sha>'

database_directory=$1
output_directory=$2
service=$3
schema=$4
environment=$5
repository=$6
commit_sha=$7

case "$service" in
  api) expected_schema=public ;;
  identity) expected_schema=identity ;;
  messaging) expected_schema=messaging ;;
  storage) expected_schema=storage ;;
  *) fail 'service must be api, identity, messaging, or storage' ;;
esac

[ "$schema" = "$expected_schema" ] \
  || fail "schema must be $expected_schema for $service"

case "$environment" in
  staging|production) ;;
  *) fail 'environment must be staging or production' ;;
esac

[ "$repository" = "tinitasker/$service" ] \
  || fail "repository must be tinitasker/$service"

printf '%s\n' "$commit_sha" | grep -Eq '^[0-9a-f]{40}$' \
  || fail 'commit SHA must be lowercase and contain exactly 40 hexadecimal characters'

[ -d "$database_directory" ] \
  || fail "database directory does not exist: $database_directory"
[ ! -L "$database_directory" ] \
  || fail 'database directory must not be a symbolic link'
[ ! -e "$output_directory" ] \
  || fail "output path already exists: $output_directory"

output_parent=${output_directory%/*}
[ "$output_parent" != "$output_directory" ] || output_parent=.
[ -d "$output_parent" ] \
  || fail "output parent directory does not exist: $output_parent"

entries=$(mktemp "${TMPDIR:-/tmp}/tinitasker-migration-entries.XXXXXX")
trap 'rm -f "$entries"' 0 HUP INT TERM

mkdir "$output_directory"
mkdir "$output_directory/db"
: > "$output_directory/manifest"
: > "$output_directory/checksums.sha256"

find "$database_directory" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort > "$entries"

migration_count=0
previous_prefix=
while IFS= read -r migration_path || [ -n "$migration_path" ]; do
  migration_name=${migration_path#"$database_directory"/}

  [ "$migration_name" != "$migration_path" ] \
    || fail "migration entry is outside the database directory: $migration_path"
  case "$migration_name" in
    */*) fail "migration entries must be direct children of $database_directory: $migration_name" ;;
    dump.sql) continue ;;
  esac

  [ -f "$migration_path" ] \
    || fail "migration entry is not a regular file: $migration_name"
  [ ! -L "$migration_path" ] \
    || fail "migration entry must not be a symbolic link: $migration_name"
  printf '%s\n' "$migration_name" \
    | grep -Eq '^[0-9]{8}__[a-z0-9_]+[.]sql$' \
    || fail "invalid migration filename: $migration_name"

  migration_prefix=${migration_name%%__*}
  [ "$migration_prefix" != "$previous_prefix" ] \
    || fail "duplicate migration prefix: $migration_prefix"
  previous_prefix=$migration_prefix

  migration_stem=${migration_name%.sql}
  migration_stem_length=$(printf '%s' "$migration_stem" | wc -c | tr -d '[:space:]')
  [ "$migration_stem_length" -le 256 ] \
    || fail "migration name is longer than the history column permits: $migration_name"

  cp "$migration_path" "$output_directory/db/$migration_name"
  printf '%s\n' "$migration_name" >> "$output_directory/manifest"
  migration_count=$((migration_count + 1))
done < "$entries"

[ "$migration_count" -gt 0 ] \
  || fail "no migrations found in $database_directory"

while IFS= read -r migration_name || [ -n "$migration_name" ]; do
  if command -v sha256sum >/dev/null 2>&1; then
    checksum=$(sha256sum "$output_directory/db/$migration_name")
  elif command -v shasum >/dev/null 2>&1; then
    checksum=$(shasum -a 256 "$output_directory/db/$migration_name")
  else
    fail 'no SHA-256 checksum utility is available'
  fi
  checksum=${checksum%% *}
  printf '%s  db/%s\n' "$checksum" "$migration_name" \
    >> "$output_directory/checksums.sha256"
done < "$output_directory/manifest"

{
  printf 'SERVICE=%s\n' "$service"
  printf 'SCHEMA=%s\n' "$schema"
  printf 'ENVIRONMENT=%s\n' "$environment"
  printf 'REPOSITORY=%s\n' "$repository"
  printf 'COMMIT_SHA=%s\n' "$commit_sha"
} > "$output_directory/metadata.env"

validator=${MIGRATION_VALIDATOR:-/usr/local/bin/validate-migration-bundle}
[ -x "$validator" ] || fail 'migration bundle validator is unavailable'
if ! "$validator" "$output_directory"; then
  fail 'packaged migration bundle failed validation'
fi

printf 'migration-packager: packaged %s migration(s) for %s/%s (%s)\n' \
  "$migration_count" "$repository" "$commit_sha" "$environment"
