#!/bin/sh
set -eu

export LC_ALL=C

bundle_directory=${1:-${MIGRATIONS_DIRECTORY:-/migrations}}
database_directory="$bundle_directory/db"
manifest="$bundle_directory/manifest"
checksums="$bundle_directory/checksums.sha256"
metadata="$bundle_directory/metadata.env"

fail() {
  printf 'migration-bundle: %s\n' "$*" >&2
  exit 1
}

is_valid_migration_filename() {
  printf '%s\n' "$1" \
    | grep -Eq '^[0-9]{8}__[a-z0-9_]+[.]sql$'
}

is_valid_sha256() {
  printf '%s\n' "$1" | grep -Eq '^[0-9a-f]{64}$'
}

is_valid_schema() {
  printf '%s\n' "$1" | grep -Eq '^[a-z_][a-z0-9_]*$'
}

[ -d "$bundle_directory" ] || fail "bundle directory is missing: $bundle_directory"
[ ! -L "$bundle_directory" ] || fail 'bundle directory must not be a symbolic link'
[ -d "$database_directory" ] || fail 'db directory is missing'
[ ! -L "$database_directory" ] || fail 'db directory must not be a symbolic link'

for required_file in "$manifest" "$checksums" "$metadata"; do
  [ -f "$required_file" ] || fail "required file is missing: ${required_file##*/}"
  [ ! -L "$required_file" ] || fail "required file must not be a symbolic link: ${required_file##*/}"
  [ -r "$required_file" ] || fail "required file is not readable: ${required_file##*/}"
done

root_entries=$(find "$bundle_directory" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
[ -n "$root_entries" ] || fail 'bundle is empty'
while IFS= read -r entry || [ -n "$entry" ]; do
  entry_name=${entry##*/}
  case "$entry_name" in
    db|manifest|checksums.sha256|metadata.env) ;;
    *) fail "unexpected bundle entry: $entry_name" ;;
  esac
done <<EOF
$root_entries
EOF

manifest_count=0
previous_name=
previous_prefix=
while IFS= read -r migration_name || [ -n "$migration_name" ]; do
  [ -n "$migration_name" ] || fail 'manifest contains an empty line'
  is_valid_migration_filename "$migration_name" \
    || fail "invalid migration filename in manifest: $migration_name"

  migration_stem=${migration_name%.sql}
  migration_stem_length=$(printf '%s' "$migration_stem" | wc -c | tr -d '[:space:]')
  [ "$migration_stem_length" -le 256 ] \
    || fail "migration name is longer than the history column permits: $migration_name"

  migration_prefix=${migration_name%%__*}
  [ "$migration_name" != "$previous_name" ] \
    || fail "duplicate migration name in manifest: $migration_name"
  [ "$migration_prefix" != "$previous_prefix" ] \
    || fail "duplicate migration prefix in manifest: $migration_prefix"

  previous_name=$migration_name
  previous_prefix=$migration_prefix
  manifest_count=$((manifest_count + 1))
done < "$manifest"

[ "$manifest_count" -gt 0 ] || fail 'manifest is empty'

manifest_contents=$(cat "$manifest")
sorted_manifest=$(LC_ALL=C sort "$manifest")
[ "$manifest_contents" = "$sorted_manifest" ] || fail 'manifest is not sorted lexically'

database_entries=$(find "$database_directory" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)
[ -n "$database_entries" ] || fail 'db directory contains no migrations'
while IFS= read -r migration_path || [ -n "$migration_path" ]; do
  migration_name=${migration_path##*/}
  [ -f "$migration_path" ] || fail "db entry is not a regular file: $migration_name"
  [ ! -L "$migration_path" ] || fail "migration must not be a symbolic link: $migration_name"
  is_valid_migration_filename "$migration_name" \
    || fail "invalid migration filename in db directory: $migration_name"
done <<EOF
$database_entries
EOF

database_names=$(find "$database_directory" -mindepth 1 -maxdepth 1 -type f -exec basename {} \; | LC_ALL=C sort)
[ "$database_names" = "$manifest_contents" ] \
  || fail 'manifest does not exactly match the files in db directory'

checksum_count=0
checksum_paths=
while IFS= read -r checksum_line || [ -n "$checksum_line" ]; do
  [ -n "$checksum_line" ] || fail 'checksums.sha256 contains an empty line'
  printf '%s\n' "$checksum_line" \
    | grep -Eq '^[0-9a-f]{64}  db/[0-9]{8}__[a-z0-9_]+[.]sql$' \
    || fail 'checksums.sha256 contains an invalid entry'

  digest=${checksum_line%%  *}
  relative_path=${checksum_line#*  }
  is_valid_sha256 "$digest" || fail 'checksums.sha256 contains an invalid digest'

  if [ -z "$checksum_paths" ]; then
    checksum_paths=$relative_path
  else
    checksum_paths="$checksum_paths
$relative_path"
  fi
  checksum_count=$((checksum_count + 1))
done < "$checksums"

[ "$checksum_count" -eq "$manifest_count" ] \
  || fail 'checksums.sha256 entry count does not match the manifest'

expected_checksum_paths=$(sed 's|^|db/|' "$manifest")
[ "$checksum_paths" = "$expected_checksum_paths" ] \
  || fail 'checksums.sha256 paths do not match the sorted manifest'

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$bundle_directory" && sha256sum -c checksums.sha256 >/dev/null 2>&1) \
    || fail 'migration checksum validation failed'
elif command -v shasum >/dev/null 2>&1; then
  (cd "$bundle_directory" && shasum -a 256 -c checksums.sha256 >/dev/null 2>&1) \
    || fail 'migration checksum validation failed'
else
  fail 'no SHA-256 checksum utility is available'
fi

metadata_count=0
seen_service=
seen_schema=
seen_environment=
seen_repository=
seen_commit_sha=
while IFS= read -r metadata_line || [ -n "$metadata_line" ]; do
  [ -n "$metadata_line" ] || fail 'metadata.env contains an empty line'
  metadata_key=${metadata_line%%=*}
  metadata_value=${metadata_line#*=}
  [ "$metadata_key" != "$metadata_line" ] || fail 'metadata.env contains an invalid entry'
  [ -n "$metadata_value" ] || fail "metadata.env value is empty: $metadata_key"

  case "$metadata_key" in
    SERVICE)
      [ -z "$seen_service" ] || fail 'metadata.env contains SERVICE more than once'
      case "$metadata_value" in api|identity|messaging|storage) ;; *) fail 'metadata.env SERVICE is invalid' ;; esac
      seen_service=$metadata_value
      ;;
    SCHEMA)
      [ -z "$seen_schema" ] || fail 'metadata.env contains SCHEMA more than once'
      is_valid_schema "$metadata_value" || fail 'metadata.env SCHEMA is invalid'
      seen_schema=$metadata_value
      ;;
    ENVIRONMENT)
      [ -z "$seen_environment" ] || fail 'metadata.env contains ENVIRONMENT more than once'
      case "$metadata_value" in staging|production) ;; *) fail 'metadata.env ENVIRONMENT is invalid' ;; esac
      seen_environment=$metadata_value
      ;;
    REPOSITORY)
      [ -z "$seen_repository" ] || fail 'metadata.env contains REPOSITORY more than once'
      printf '%s\n' "$metadata_value" | grep -Eq '^tinitasker/(api|identity|messaging|storage)$' \
        || fail 'metadata.env REPOSITORY is invalid'
      seen_repository=$metadata_value
      ;;
    COMMIT_SHA)
      [ -z "$seen_commit_sha" ] || fail 'metadata.env contains COMMIT_SHA more than once'
      printf '%s\n' "$metadata_value" | grep -Eq '^[0-9a-f]{40}$' \
        || fail 'metadata.env COMMIT_SHA is invalid'
      seen_commit_sha=$metadata_value
      ;;
    *) fail "metadata.env contains an unknown key: $metadata_key" ;;
  esac
  metadata_count=$((metadata_count + 1))
done < "$metadata"

[ "$metadata_count" -eq 5 ] || fail 'metadata.env must contain exactly five entries'
[ -n "$seen_service" ] || fail 'metadata.env is missing SERVICE'
[ -n "$seen_schema" ] || fail 'metadata.env is missing SCHEMA'
[ -n "$seen_environment" ] || fail 'metadata.env is missing ENVIRONMENT'
[ -n "$seen_repository" ] || fail 'metadata.env is missing REPOSITORY'
[ -n "$seen_commit_sha" ] || fail 'metadata.env is missing COMMIT_SHA'

expected_repository="tinitasker/$seen_service"
[ "$seen_repository" = "$expected_repository" ] \
  || fail 'metadata.env REPOSITORY does not match SERVICE'

case "$seen_service" in
  api) expected_schema=public ;;
  identity) expected_schema=identity ;;
  messaging) expected_schema=messaging ;;
  storage) expected_schema=storage ;;
esac
[ "$seen_schema" = "$expected_schema" ] \
  || fail 'metadata.env SCHEMA does not match SERVICE'
