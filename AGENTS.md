# TiniTasker Migrations Runner — Agent Instructions

Read the [organization engineering handbook](https://github.com/tinitasker/.github/blob/main/docs/README.md) first. It contains the shared workflow; this file is specific to the migration image.

## Local scope

This repository builds the universal PostgreSQL 18 migration image used to package and execute service-owned migrations. Its interfaces are consumed by `api`, `identity`, `messaging`, `storage`, and the shared `actions` repository.

Preserve the validated bundle format, service/schema allowlist, checksum verification, unprivileged container behavior, and exact digest-pinning contract. Do not put database credentials, service source, or migrations into the runner image.

## Local validation and delivery

```sh
make test
make integration-test
make build
```

Use Docker or Podman via `CONTAINER_ENGINE` as appropriate. Publishing the GHCR image is a deliberate manual operation after validation. Any interface change requires coordinated PRs in every consumer and an explicit rollout plan.
