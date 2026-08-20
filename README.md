# TiniTasker migrations runner

This project builds the universal PostgreSQL 18 migration image used to both
package and execute service-owned migrations:

```text
ghcr.io/tinitasker/migrations-runner@sha256:<digest>
```

## Repository bootstrap

This folder must be initialized as its own Git repository and pushed to the
`tinitasker/migrations-runner` GitHub repository before its verification and
release workflows can run. The surrounding `tinitasker` workspace is not a Git
repository and does not publish this project implicitly.

Create the empty organization repository first, then initialize and publish
this folder from its root:

```sh
git init
git branch -M main
git remote add origin git@github.com:tinitasker/migrations-runner.git
# Review, add, and commit the project files before publishing them.
git push --set-upstream origin main
```

Do not create a GitHub Release until `main` exists remotely and the repository
workflow has passed. Repository creation, initialization, and the first push
are deliberate one-time operator actions; Terraform does not perform them.

GitHub-hosted workflow jobs use the image's `package-migrations` command to
create a migration bundle, then upload that bundle as a GitHub Actions
artifact. The dedicated DigitalOcean self-hosted runner downloads the artifact
and mounts it into the same image at `/migrations:ro` for execution. Service
repositories therefore need no migration packaging scripts of their own.

The GHCR package is expected to be public because it contains no database
credentials, application code, or service migrations. This lets pull-request
workflows and the restricted self-hosted runner pull an immutable digest
without a long-lived registry credential. If the package is made private,
both environments need an explicit read-only GHCR credential instead.

## Packaging interface

The image installs the packager at `/usr/local/bin/package-migrations`. Override
the default entrypoint when creating an artifact:

```sh
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --read-only \
  --cap-drop=all \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --entrypoint /usr/local/bin/package-migrations \
  --mount type=bind,src="$PWD/db",dst=/source/db,readonly \
  --mount type=bind,src="$RUNNER_TEMP",dst=/output \
  ghcr.io/tinitasker/migrations-runner@sha256:<digest> \
  /source/db \
  /output/migration-bundle \
  api \
  public \
  staging \
  tinitasker/api \
  "$GITHUB_SHA"
```

The arguments are the source `db` directory, a new output directory, service,
schema, environment, repository, and lowercase 40-character commit SHA. The
output directory must not already exist and its parent must be writable.

The packager sorts filenames using the C locale, skips `dump.sql`, and copies
only regular files matching `^[0-9]{8}__[a-z0-9_]+\.sql$`. It rejects every
other entry, symbolic links, duplicate numeric prefixes, invalid service/schema
pairs, and empty migration sets. It computes the artifact checksums and runs
the full bundle validator before returning success.

## Bundle contract

The mounted directory must have exactly this layout:

```text
/migrations/
  db/
    00000000__baseline.sql
    00000001__example.sql
  manifest
  checksums.sha256
  metadata.env
```

`db` may contain only regular, non-symlink files matching
`^[0-9]{8}__[a-z0-9_]+\.sql$`. Numeric gaps are allowed, but duplicate numeric
prefixes are rejected. The runner requires `manifest` to list every SQL file
exactly once in lexical order.

`checksums.sha256` uses the standard two-space SHA-256 format and follows the
same order:

```text
<64 lowercase hex characters>  db/00000000__baseline.sql
<64 lowercase hex characters>  db/00000001__example.sql
```

`metadata.env` is data, not a shell script. It must contain exactly these five
entries; the runner parses it without sourcing it:

```dotenv
SERVICE=api
SCHEMA=public
ENVIRONMENT=staging
REPOSITORY=tinitasker/api
COMMIT_SHA=0123456789abcdef0123456789abcdef01234567
```

The supported service/schema pairs are:

| Service | Schema |
| --- | --- |
| `api` | `public` |
| `identity` | `identity` |
| `messaging` | `messaging` |
| `storage` | `storage` |

Bundle metadata must match the job environment. This prevents a valid artifact
for one service, environment, or commit from being used accidentally by
another migration job.

## Runtime interface

The required environment variables are:

- `MIGRATION_SERVICE`
- `MIGRATION_SCHEMA`
- `MIGRATION_COMMIT_SHA` (the lowercase 40-character service commit SHA)
- `ASPNETCORE_ENVIRONMENT` (`Staging` or `Production`)
- `PGHOST`
- `PGPORT`
- `PGDATABASE`
- `PGUSER`
- `PGPASSWORD`
- `PGSSLMODE=require`

The bundle location defaults to `/migrations`. `MIGRATIONS_DIRECTORY` exists
for local testing but should not be overridden by deployment workflows.

The migration Droplet runs the image with rootless Podman. The workflow must
pin the public GHCR image by digest.

Example invocation on the dedicated runner:

```sh
podman run --rm --read-only \
  --cap-drop=all \
  --security-opt=no-new-privileges \
  --mount type=bind,src="$PWD/migration-bundle",dst=/migrations,readonly \
  --env MIGRATION_SERVICE=api \
  --env MIGRATION_SCHEMA=public \
  --env MIGRATION_COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 \
  --env ASPNETCORE_ENVIRONMENT=Staging \
  --env PGHOST \
  --env PGPORT \
  --env PGDATABASE \
  --env PGUSER \
  --env PGPASSWORD \
  --env PGSSLMODE=require \
  ghcr.io/tinitasker/migrations-runner@sha256:<digest>
```

The same invocation works with Docker by replacing `podman` with `docker`.
The container declares the unprivileged PostgreSQL user and does not write to
the image filesystem or migration bundle.

Use the managed database's private/direct endpoint. The dedicated runner must
be a trusted database source; application containers and GitHub-hosted runners
do not need database credentials.

## Execution behavior

Before connecting to PostgreSQL, the runner validates the complete bundle,
checks every SHA-256 digest, and confirms its metadata matches the job. It then:

1. Creates the configured schema and `__migrations` table if absent.
2. Reads the lexically sorted manifest.
3. Looks up the exact filename stem in `<schema>.__migrations`.
4. Logs `Skipping migration <stem>` when it is already recorded.
5. Executes a pending SQL file with `psql` and `ON_ERROR_STOP=1`.
6. Inserts the stem into the history table only after `psql` succeeds.

The runner never starts a transaction and never uses `--single-transaction`.
Each migration file decides whether and where it needs transaction boundaries.
Consequently, a script that partially succeeds and then fails is not recorded,
but PostgreSQL cannot automatically undo statements that the script committed.
Migrations should remain idempotent and expand/contract compatible.

Runner lifecycle records are compact JSON with top-level `env` and `service`
properties, plus an event name and the artifact repository/commit. Bootstrap,
validation, and PostgreSQL diagnostics may also be written as plain text to
standard error.

## Development

Run the portable shell test suite:

```sh
make test
```

Run the Docker integration suite against a disposable TLS-enabled PostgreSQL
18 container:

```sh
make integration-test
```

The integration suite builds the runner image, packages a representative
artifact, verifies first-run and repeated-run behavior against real PostgreSQL,
and confirms that a failed nontransactional migration is not journaled. It
uses only uniquely named disposable Docker resources and removes them on exit.

Build the PostgreSQL 18 image:

```sh
make build IMAGE=tinitasker/migrations-runner:local
```

To build with rootless Podman instead:

```sh
make build CONTAINER_ENGINE=podman IMAGE=tinitasker/migrations-runner:local
```

To publish an immutable commit image to GHCR from an authenticated workstation
or CI job with package-write permission:

```sh
export MIGRATIONS_IMAGE="ghcr.io/tinitasker/migrations-runner:sha-<full-commit-sha>"
docker buildx build --platform linux/amd64 --tag "$MIGRATIONS_IMAGE" --push .
docker buildx imagetools inspect "$MIGRATIONS_IMAGE"
```

Use GitHub's workflow token for publishing from this repository, make the GHCR
package public, and reference the resolved digest in service workflows rather
than relying on a mutable tag.

The repository workflows verify pull requests and `main` pushes in the order
validate, advisory SAST scan, image build, and portable tests. Publishing is
triggered only by a stable GitHub Release named `vX.Y.Z`; listening to both tag
pushes and releases would run the same publication twice. The release commit
must belong to `main`, the version must increase monotonically, and existing
immutable GHCR tags are rejected. A successful release publishes `vX.Y.Z`,
`X.Y.Z`, `sha-<commit>`, and `latest`, then records the digest-qualified image
reference in the workflow summary.

After the first package version is published, perform this one-time GitHub
organization action before enabling service workflows:

1. Open the `tinitasker/migrations-runner` package settings.
2. Change package visibility to **Public**.
3. Keep service workflows configured with the exact
   `ghcr.io/tinitasker/migrations-runner@sha256:<digest>` printed by the release
   workflow.

Only `latest` is mutable. Service workflows must never use it.
