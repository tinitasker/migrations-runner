#!/bin/sh
set -eu

project_directory=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
packager="$project_directory/scripts/package-migrations.sh"
runner="$project_directory/scripts/run-migrations.sh"
validator="$project_directory/scripts/validate-migration-bundle.sh"
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/tinitasker-migrations-runner.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

passed=0

pass() {
  passed=$((passed + 1))
  printf 'ok %s - %s\n' "$passed" "$1"
}

fail_test() {
  printf 'not ok %s - %s\n' "$((passed + 1))" "$1" >&2
  exit 1
}

assert_contains() {
  file=$1
  expected=$2
  grep -F "$expected" "$file" >/dev/null \
    || fail_test "expected $file to contain: $expected"
}

assert_not_contains() {
  file=$1
  unexpected=$2
  if grep -F -- "$unexpected" "$file" >/dev/null; then
    fail_test "expected $file not to contain: $unexpected"
  fi
}

write_checksums() {
  bundle=$1
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$bundle" && while IFS= read -r migration; do sha256sum "db/$migration"; done < manifest) \
      > "$bundle/checksums.sha256"
  else
    (cd "$bundle" && while IFS= read -r migration; do shasum -a 256 "db/$migration"; done < manifest) \
      > "$bundle/checksums.sha256"
  fi
}

make_bundle() {
  bundle=$1
  mkdir -p "$bundle/db"
  printf '%s\n' 'create table if not exists first_table (id integer);' \
    > "$bundle/db/00000001__first.sql"
  printf '%s\n' 'begin;' 'create table if not exists second_table (id integer);' 'commit;' \
    > "$bundle/db/00000003__second.sql"
  printf '%s\n' '00000001__first.sql' '00000003__second.sql' > "$bundle/manifest"
  write_checksums "$bundle"
  printf '%s\n' \
    'SERVICE=api' \
    'SCHEMA=public' \
    'ENVIRONMENT=staging' \
    'REPOSITORY=tinitasker/api' \
    'COMMIT_SHA=0123456789abcdef0123456789abcdef01234567' \
    > "$bundle/metadata.env"
}

fake_bin="$temporary_directory/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/psql" <<'EOF'
#!/bin/sh
set -eu

{
  printf '%s' 'ARGS'
  for argument in "$@"; do
    printf '|%s' "$argument"
  done
  printf '\n'
} >> "$FAKE_PSQL_LOG"

command_text=
file_path=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      shift
      command_text=$1
      ;;
    --command=*) command_text=${1#--command=} ;;
    --file)
      shift
      file_path=$1
      ;;
    --file=*) file_path=${1#--file=} ;;
  esac
  shift
done

if [ -n "$file_path" ]; then
  migration_name=${file_path##*/}
  printf 'FILE:%s\n' "$migration_name" >> "$FAKE_PSQL_LOG"
  if grep -F 'FAIL_MIGRATION' "$file_path" >/dev/null; then
    printf 'simulated migration failure\n' >&2
    exit 1
  fi
  exit 0
fi

case "$command_text" in
  *'CREATE SCHEMA IF NOT EXISTS'*)
    printf '%s\n' 'INITIALIZE' >> "$FAKE_PSQL_LOG"
    ;;
  *'SELECT EXISTS'*)
    migration_stem=$(printf '%s\n' "$command_text" | sed -n "s/.*WHERE \"name\" = '\([^']*\)'.*/\1/p")
    printf 'CHECK:%s\n' "$migration_stem" >> "$FAKE_PSQL_LOG"
    if [ -f "$FAKE_PSQL_STATE" ] && grep -F -x "$migration_stem" "$FAKE_PSQL_STATE" >/dev/null; then
      printf '%s\n' 't'
    else
      printf '%s\n' 'f'
    fi
    ;;
  *'INSERT INTO'*)
    migration_stem=$(printf '%s\n' "$command_text" | sed -n "s/.*VALUES ('\([^']*\)').*/\1/p")
    printf 'INSERT:%s\n' "$migration_stem" >> "$FAKE_PSQL_LOG"
    printf '%s\n' "$migration_stem" >> "$FAKE_PSQL_STATE"
    ;;
  *)
    printf 'unexpected psql command: %s\n' "$command_text" >&2
    exit 1
    ;;
esac
EOF
chmod 0755 "$fake_bin/psql"

run_bundle() {
  bundle=$1
  output=$2
  port=${3:-25060}
  PATH="$fake_bin:$PATH" \
  FAKE_PSQL_LOG="$temporary_directory/psql.log" \
  FAKE_PSQL_STATE="$temporary_directory/psql.state" \
  MIGRATION_VALIDATOR="$validator" \
  MIGRATIONS_DIRECTORY="$bundle" \
  MIGRATION_SERVICE=api \
  MIGRATION_SCHEMA=public \
  ASPNETCORE_ENVIRONMENT=Staging \
  MIGRATION_COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
  PGHOST=database.internal \
  PGPORT="$port" \
  PGDATABASE=defaultdb \
  PGUSER=migrations \
  PGPASSWORD=not-a-real-secret \
  PGSSLMODE=require \
    "$runner" > "$output" 2>&1
}

source_database="$temporary_directory/source-db"
mkdir "$source_database"
printf '%s\n' 'create table if not exists first_table (id integer);' \
  > "$source_database/00000001__first.sql"
printf '%s\n' 'begin;' 'create table if not exists second_table (id integer);' 'commit;' \
  > "$source_database/00000003__second.sql"
printf '%s\n' 'this file must never be packaged' > "$source_database/dump.sql"

packaged_bundle="$temporary_directory/packaged"
MIGRATION_VALIDATOR="$validator" \
  "$packager" \
    "$source_database" \
    "$packaged_bundle" \
    api \
    public \
    staging \
    tinitasker/api \
    0123456789abcdef0123456789abcdef01234567 \
    > "$temporary_directory/package.log"

expected_manifest='00000001__first.sql
00000003__second.sql'
[ "$(cat "$packaged_bundle/manifest")" = "$expected_manifest" ] \
  || fail_test 'packager did not produce the expected lexical manifest'
[ ! -e "$packaged_bundle/db/dump.sql" ] \
  || fail_test 'packager included dump.sql'
assert_contains "$packaged_bundle/metadata.env" 'SERVICE=api'
assert_contains "$packaged_bundle/metadata.env" 'SCHEMA=public'
assert_contains "$packaged_bundle/metadata.env" 'ENVIRONMENT=staging'
assert_contains "$packaged_bundle/metadata.env" 'REPOSITORY=tinitasker/api'
assert_contains "$packaged_bundle/metadata.env" \
  'COMMIT_SHA=0123456789abcdef0123456789abcdef01234567'
"$validator" "$packaged_bundle"
pass 'packages a complete validated artifact and excludes dump.sql'

invalid_source="$temporary_directory/invalid-source"
cp -R "$source_database" "$invalid_source"
printf '%s\n' 'not a migration' > "$invalid_source/README.txt"
if MIGRATION_VALIDATOR="$validator" \
  "$packager" "$invalid_source" "$temporary_directory/invalid-package" \
    api public staging tinitasker/api \
    0123456789abcdef0123456789abcdef01234567 \
    > "$temporary_directory/invalid-package.log" 2>&1; then
  fail_test 'packager accepted a non-migration database entry'
fi
assert_contains "$temporary_directory/invalid-package.log" \
  'invalid migration filename: README.txt'
pass 'packager rejects every nonconforming database entry'

duplicate_source="$temporary_directory/duplicate-source"
cp -R "$source_database" "$duplicate_source"
printf '%s\n' 'select 3;' > "$duplicate_source/00000003__duplicate.sql"
if MIGRATION_VALIDATOR="$validator" \
  "$packager" "$duplicate_source" "$temporary_directory/duplicate-package" \
    api public staging tinitasker/api \
    0123456789abcdef0123456789abcdef01234567 \
    > "$temporary_directory/duplicate-package.log" 2>&1; then
  fail_test 'packager accepted a duplicate migration prefix'
fi
assert_contains "$temporary_directory/duplicate-package.log" \
  'duplicate migration prefix: 00000003'
pass 'packager rejects duplicate prefixes while permitting numeric gaps'

if MIGRATION_VALIDATOR="$validator" \
  "$packager" "$source_database" "$temporary_directory/mismatched-package" \
    api identity staging tinitasker/api \
    0123456789abcdef0123456789abcdef01234567 \
    > "$temporary_directory/mismatched-package.log" 2>&1; then
  fail_test 'packager accepted a mismatched service/schema pair'
fi
assert_contains "$temporary_directory/mismatched-package.log" \
  'schema must be public for api'
pass 'packager enforces supported service, schema, and repository pairs'

invalid_schema_bundle="$temporary_directory/invalid-schema-bundle"
cp -R "$packaged_bundle" "$invalid_schema_bundle"
sed 's/^SCHEMA=public$/SCHEMA=identity/' \
  "$packaged_bundle/metadata.env" > "$invalid_schema_bundle/metadata.env"
if "$validator" "$invalid_schema_bundle" \
  > "$temporary_directory/invalid-schema-bundle.log" 2>&1; then
  fail_test 'validator accepted a mismatched service/schema pair'
fi
assert_contains "$temporary_directory/invalid-schema-bundle.log" \
  'metadata.env SCHEMA does not match SERVICE'
pass 'validator enforces supported service and schema pairs'

valid_bundle="$temporary_directory/valid"
make_bundle "$valid_bundle"
"$validator" "$valid_bundle"
pass 'accepts the exact validated bundle layout'

if run_bundle "$valid_bundle" "$temporary_directory/oversized-port.log" \
  999999999999999999999999999999999999999999; then
  fail_test 'runner accepted a numeric PGPORT outside the shell integer range'
fi
assert_contains "$temporary_directory/oversized-port.log" \
  'PGPORT must be between 1 and 65535'
pass 'rejects PGPORT values outside the shell integer range'

: > "$temporary_directory/psql.log"
: > "$temporary_directory/psql.state"
first_output="$temporary_directory/first-output.log"
run_bundle "$valid_bundle" "$first_output"
execution_order=$(grep -E '^(FILE|INSERT):' "$temporary_directory/psql.log")
expected_order='FILE:00000001__first.sql
INSERT:00000001__first
FILE:00000003__second.sql
INSERT:00000003__second'
[ "$execution_order" = "$expected_order" ] \
  || fail_test 'migrations were not executed and journaled in lexical order'
assert_contains "$first_output" '"env":"staging","service":"api"'
assert_contains "$first_output" '"event":"migration.completed"'
assert_not_contains "$temporary_directory/psql.log" '--single-transaction'
pass 'runs SQL as authored, journals afterward, and emits structured fields'

second_output="$temporary_directory/second-output.log"
run_bundle "$valid_bundle" "$second_output"
assert_contains "$second_output" '"message":"Skipping migration 00000001__first"'
assert_contains "$second_output" '"message":"Skipping migration 00000003__second"'
assert_contains "$second_output" 'applied=0 skipped=2'
pass 'skips exact migration stems already present in the journal'

tampered_bundle="$temporary_directory/tampered"
cp -R "$valid_bundle" "$tampered_bundle"
printf '%s\n' 'select 42;' >> "$tampered_bundle/db/00000001__first.sql"
if "$validator" "$tampered_bundle" > "$temporary_directory/tampered.log" 2>&1; then
  fail_test 'checksum tampering was accepted'
fi
assert_contains "$temporary_directory/tampered.log" 'migration checksum validation failed'
pass 'rejects a bundle whose migration content does not match its checksum'

invalid_file_bundle="$temporary_directory/invalid-file"
cp -R "$valid_bundle" "$invalid_file_bundle"
printf '%s\n' 'not a migration' > "$invalid_file_bundle/db/dump.sql"
if "$validator" "$invalid_file_bundle" > "$temporary_directory/invalid-file.log" 2>&1; then
  fail_test 'an invalid migration filename was accepted'
fi
assert_contains "$temporary_directory/invalid-file.log" 'invalid migration filename in db directory: dump.sql'
pass 'rejects dump.sql and every nonconforming database entry'

duplicate_prefix_bundle="$temporary_directory/duplicate-prefix"
cp -R "$valid_bundle" "$duplicate_prefix_bundle"
printf '%s\n' 'select 2;' > "$duplicate_prefix_bundle/db/00000003__duplicate.sql"
printf '%s\n' '00000001__first.sql' '00000003__duplicate.sql' '00000003__second.sql' \
  > "$duplicate_prefix_bundle/manifest"
write_checksums "$duplicate_prefix_bundle"
if "$validator" "$duplicate_prefix_bundle" > "$temporary_directory/duplicate-prefix.log" 2>&1; then
  fail_test 'a duplicate migration prefix was accepted'
fi
assert_contains "$temporary_directory/duplicate-prefix.log" 'duplicate migration prefix in manifest: 00000003'
pass 'rejects duplicate migration prefixes while allowing numeric gaps'

metadata_bundle="$temporary_directory/metadata-mismatch"
cp -R "$valid_bundle" "$metadata_bundle"
sed 's/^SERVICE=api$/SERVICE=identity/; s/^SCHEMA=public$/SCHEMA=identity/; s|^REPOSITORY=tinitasker/api$|REPOSITORY=tinitasker/identity|' \
  "$valid_bundle/metadata.env" > "$metadata_bundle/metadata.env"
if run_bundle "$metadata_bundle" "$temporary_directory/metadata-mismatch.log"; then
  fail_test 'bundle metadata mismatch was accepted'
fi
assert_contains "$temporary_directory/metadata-mismatch.log" 'Bundle SERVICE does not match MIGRATION_SERVICE'
pass 'rejects bundle metadata that does not match the job configuration'

commit_bundle="$temporary_directory/commit-mismatch"
cp -R "$valid_bundle" "$commit_bundle"
sed 's/^COMMIT_SHA=.*/COMMIT_SHA=ffffffffffffffffffffffffffffffffffffffff/' \
  "$valid_bundle/metadata.env" > "$commit_bundle/metadata.env"
if run_bundle "$commit_bundle" "$temporary_directory/commit-mismatch.log"; then
  fail_test 'bundle commit mismatch was accepted'
fi
assert_contains "$temporary_directory/commit-mismatch.log" \
  'Bundle COMMIT_SHA does not match MIGRATION_COMMIT_SHA'
pass 'rejects bundle metadata for a different service commit'

failing_bundle="$temporary_directory/failing"
cp -R "$valid_bundle" "$failing_bundle"
printf '%s\n' 'FAIL_MIGRATION' > "$failing_bundle/db/00000005__failing.sql"
printf '%s\n' '00000001__first.sql' '00000003__second.sql' '00000005__failing.sql' \
  > "$failing_bundle/manifest"
write_checksums "$failing_bundle"
: > "$temporary_directory/psql.log"
: > "$temporary_directory/psql.state"
if run_bundle "$failing_bundle" "$temporary_directory/failing.log"; then
  fail_test 'a failing migration returned success'
fi
assert_contains "$temporary_directory/psql.log" 'FILE:00000005__failing.sql'
assert_not_contains "$temporary_directory/psql.log" 'INSERT:00000005__failing'
assert_contains "$temporary_directory/failing.log" '"event":"migration.failed"'
pass 'does not journal a migration when its SQL execution fails'

printf '1..%s\n' "$passed"
