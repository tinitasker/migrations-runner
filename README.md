# TiniTasker migrations runner

This project builds the universal PostgreSQL 18 migration image used to both
package and execute service-owned migrations:

```text
ghcr.io/tinitasker/migrations-runner@sha256:<digest>
```

## Repository bootstrap

This folder is its own Git repository; the surrounding `tinitasker` workspace
does not publish it implicitly. The existing `tinitasker/migrations-runner`
repository is already initialized.

For a new empty organization repository, create a seed default `main` branch
during repository provisioning (for example, by creating it with an initial
README). Apply the organization `main` ruleset immediately. Then use the
standard [`feature/<short-meaningful-description>` draft-PR flow](https://github.com/tinitasker/.github/blob/main/docs/development-flow.md)
for every code or configuration change. Do not push later work directly to
`main`.

GitHub-hosted workflow jobs use the image's `package-migrations` command to
create a migration bundle, then upload that bundle as a GitHub Actions
artifact. The dedicated DigitalOcean self-hosted runner downloads the artifact
and mounts it into the same image at `/migrations:ro` for execution. Service
repositories therefore need no migration packaging scripts of their own.

## Shared composite action

The shared `tinitasker/actions/migrations/run` composite action owns the
self-hosted half of the handoff: it creates a private temporary directory,
downloads one named artifact from the current workflow run, verifies its
metadata, pulls the digest-pinned image, executes it with rootless Podman, and
removes temporary files in an `always` cleanup step. The image performs the
bundle checksum and path validation at execution time.

The calling job, not the action, chooses the runner. Keep the `migrate` job on
the restricted database runner group and make it depend on the job that uploads
the migration artifact. Do not check out service source code in that job.

```yaml
migrate:
  needs: prepare-migrations
  runs-on:
    group: staging-db-migrations
    labels: tinitasker-staging-db
  environment:
    name: staging
  permissions:
    actions: read
  steps:
    - uses: tinitasker/actions/migrations/run@<full-commit-sha>
      with:
        artifact-name: migrations-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}
        runner-image: ${{ needs.validate.outputs.migrations_runner_image }}
        service: api
        environment: staging
        commit-sha: ${{ github.sha }}
        expected-database: tinitasker_staging
      env:
        PGHOST: ${{ secrets.PGHOST }}
        PGPORT: ${{ secrets.PGPORT }}
        PGDATABASE: ${{ secrets.PGDATABASE }}
        PGUSER: ${{ secrets.PGUSER }}
        PGPASSWORD: ${{ secrets.PGPASSWORD }}
```

Pass database credentials as step environment variables, not action inputs.
The action pulls the documented public runner image without registry credentials
by default. If the package is deliberately private, set
`registry-auth-required: true` and provide `GHCR_USERNAME` and `GHCR_TOKEN` as
step environment variables. Pin the action reference to the exact reviewed
commit after publishing it. A version tag is convenient for releases, but a
full commit SHA is the immutable deployment reference.

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
validate, advisory SAST scan, image build, and portable tests. Publishing runs
only when an operator manually starts **Publish migrations runner** and enters a
stable `X.Y.Z` version. The selected revision must belong to `main`, the version
must increase monotonically relative to published GHCR package tags, and
existing immutable GHCR tags are rejected. A successful run publishes
`vX.Y.Z`, `X.Y.Z`, `sha-<commit>`, and `latest`, then records the
digest-qualified image reference in the workflow summary.

After the first package version is published, perform this one-time GitHub
organization action before enabling service workflows:

1. Open the `tinitasker/migrations-runner` package settings.
2. Change package visibility to **Public**.
3. Keep service workflows configured with the exact
   `ghcr.io/tinitasker/migrations-runner@sha256:<digest>` printed by the publishing
   workflow.

Only `latest` is mutable. Service workflows must never use it.
