#!/usr/bin/env bash
set -euo pipefail

export LC_ALL=C

fail() {
  printf 'migration-action: %s\n' "$*" >&2
  exit 1
}

require_setting() {
  local name=$1
  [[ -n "${!name:-}" ]] || fail "$name is required"
}

require_setting MIGRATION_ARTIFACT_DIRECTORY
require_setting MIGRATIONS_RUNNER_IMAGE
require_setting MIGRATION_SERVICE
require_setting MIGRATION_ENVIRONMENT
require_setting MIGRATION_COMMIT_SHA
require_setting MIGRATION_EXPECTED_DATABASE
require_setting MIGRATION_REGISTRY_AUTH_REQUIRED

case "$MIGRATION_SERVICE" in
  api) migration_schema=public ;;
  identity) migration_schema=identity ;;
  messaging) migration_schema=messaging ;;
  storage) migration_schema=storage ;;
  *) fail 'MIGRATION_SERVICE must be api, identity, messaging, or storage' ;;
esac

case "$MIGRATION_ENVIRONMENT" in
  staging) aspnetcore_environment=Staging ;;
  production) aspnetcore_environment=Production ;;
  *) fail 'MIGRATION_ENVIRONMENT must be staging or production' ;;
esac

[[ "$MIGRATIONS_RUNNER_IMAGE" =~ ^ghcr\.io/tinitasker/migrations-runner@sha256:[0-9a-f]{64}$ ]] \
  || fail 'MIGRATIONS_RUNNER_IMAGE must pin ghcr.io/tinitasker/migrations-runner by sha256 digest'
[[ "$MIGRATION_COMMIT_SHA" =~ ^[0-9a-f]{40}$ ]] \
  || fail 'MIGRATION_COMMIT_SHA must be a lowercase 40-character Git commit SHA'
[[ -d "$MIGRATION_ARTIFACT_DIRECTORY" ]] \
  || fail 'Migration artifact directory is missing'
[[ ! -L "$MIGRATION_ARTIFACT_DIRECTORY" ]] \
  || fail 'Migration artifact directory must not be a symbolic link'

for setting in PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD; do
  require_setting "$setting"
done

[[ "$PGDATABASE" == "$MIGRATION_EXPECTED_DATABASE" ]] \
  || fail "PGDATABASE must be $MIGRATION_EXPECTED_DATABASE"

expected_metadata="$(printf '%s\n' \
  "SERVICE=$MIGRATION_SERVICE" \
  "SCHEMA=$migration_schema" \
  "ENVIRONMENT=$MIGRATION_ENVIRONMENT" \
  "REPOSITORY=$GITHUB_REPOSITORY" \
  "COMMIT_SHA=$MIGRATION_COMMIT_SHA")"
metadata_path="$MIGRATION_ARTIFACT_DIRECTORY/metadata.env"
[[ -f "$metadata_path" && ! -L "$metadata_path" ]] \
  || fail 'Migration artifact metadata.env is missing or unsafe'
actual_metadata="$(cat "$metadata_path")"
[[ "$actual_metadata" == "$expected_metadata" ]] \
  || fail 'Migration artifact metadata does not match this service, environment, repository, and commit'

command -v podman >/dev/null 2>&1 \
  || fail 'Podman is required on the self-hosted migration runner'

auth_directory=
cleanup_registry_auth() {
  if [[ -n "$auth_directory" && -d "$auth_directory" ]]; then
    find "$auth_directory" -xdev -depth -delete
  fi
}
trap cleanup_registry_auth EXIT HUP INT TERM

case "$MIGRATION_REGISTRY_AUTH_REQUIRED" in
  true)
    use_registry_auth=true
    ;;
  false)
    if [[ -n "${GHCR_USERNAME:-}" || -n "${GHCR_TOKEN:-}" ]]; then
      use_registry_auth=true
    else
      use_registry_auth=false
    fi
    ;;
  *) fail 'MIGRATION_REGISTRY_AUTH_REQUIRED must be true or false' ;;
esac

if [[ "$use_registry_auth" == true ]]; then
  require_setting GHCR_USERNAME
  require_setting GHCR_TOKEN

  temp_parent="$(cd -- "$RUNNER_TEMP" && pwd -P)"
  auth_directory="$(mktemp -d "$temp_parent/tinitasker-ghcr-auth.XXXXXXXX")"
  chmod 700 "$auth_directory"
  auth_file="$auth_directory/auth.json"

  printf '%s' "$GHCR_TOKEN" | podman login \
    --authfile "$auth_file" \
    --username "$GHCR_USERNAME" \
    --password-stdin \
    ghcr.io
  unset GHCR_TOKEN
  podman pull --authfile "$auth_file" "$MIGRATIONS_RUNNER_IMAGE"
  cleanup_registry_auth
  auth_directory=
else
  podman pull "$MIGRATIONS_RUNNER_IMAGE"
fi

trap - EXIT HUP INT TERM

export ASPNETCORE_ENVIRONMENT="$aspnetcore_environment"
export MIGRATION_SCHEMA="$migration_schema"
export PGSSLMODE=require

podman run --rm \
  --pull=never \
  --read-only \
  --cap-drop=all \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --volume "$MIGRATION_ARTIFACT_DIRECTORY:/migrations:ro" \
  --env ASPNETCORE_ENVIRONMENT \
  --env MIGRATION_SERVICE \
  --env MIGRATION_SCHEMA \
  --env MIGRATION_COMMIT_SHA \
  --env PGHOST \
  --env PGPORT \
  --env PGDATABASE \
  --env PGUSER \
  --env PGPASSWORD \
  --env PGSSLMODE \
  "$MIGRATIONS_RUNNER_IMAGE"
