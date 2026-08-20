FROM alpine:3.23@sha256:fd791d74b68913cbb027c6546007b3f0d3bc45125f797758156952bc2d6daf40

LABEL org.opencontainers.image.title="TiniTasker migrations runner" \
      org.opencontainers.image.description="Packages and runs validated, service-owned PostgreSQL migrations" \
      org.opencontainers.image.source="https://github.com/tinitasker/migrations-runner"

ENV MIGRATIONS_DIRECTORY=/migrations \
    PGSSLMODE=require

COPY scripts/validate-migration-bundle.sh /usr/local/bin/validate-migration-bundle
COPY scripts/package-migrations.sh /usr/local/bin/package-migrations
COPY scripts/run-migrations.sh /usr/local/bin/run-migrations

RUN apk add --no-cache postgresql18-client \
    && chmod 0555 \
      /usr/local/bin/validate-migration-bundle \
      /usr/local/bin/package-migrations \
      /usr/local/bin/run-migrations \
    && mkdir -p /migrations \
    && chown postgres:postgres /migrations

# The runner only needs to read its mounted bundle and connect to PostgreSQL.
# Running as the image's unprivileged postgres user also makes --read-only safe.
USER postgres
WORKDIR /migrations

ENTRYPOINT ["/usr/local/bin/run-migrations"]
