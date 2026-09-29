# Production deployment and rollback

## Pre-deploy

1. Confirm the intended release SHA and review every migration in the release range.
2. Confirm a recent successful completed bundle has been copied to approved encrypted off-host storage. For a risky migration, require a fresh restore-verified backup.
3. Run `bin/ops/preflight` in the candidate production runtime. It prints variable names/statuses only, checks the four databases independently, checks storage configuration/writability, verifies `pg_dump`/`pg_restore`, pending migrations, Solid Queue configuration, recurring schedule parsing, and eager loading, and never calls OpenRouter. `--json` provides the same bounded fields.
4. Confirm the `three_heavens_storage:/rails/storage` Kamal volume is attached and writable by uid/gid 1000.
5. Confirm `/up`, `/ready`, queue processing, and the old environment's admin Operations diagnostics are healthy enough for deployment.
6. Determine code/schema rollback compatibility. Do not deploy a destructive same-release schema removal. Use expand, deploy compatible code, migrate/backfill, then contract in a later independently backed-up release.
7. Configure the edge proxy to reject request bodies larger than 21 MiB. This permits the supported Translation Reference request containing two files of at most 10 MiB each plus 1 MiB of multipart overhead; per-file application validation remains authoritative. The application rejects declared bodies above 21 MiB before parsing and bounds undeclared bodies to 21 MiB while reading them, but the proxy remains the first line of defense for chunked requests without `Content-Length`.

## Deploy

Use the repository's installed Kamal command from a trusted operator workstation after supplying the variable names documented in the README:

```sh
bin/kamal deploy
```

Kamal Proxy uses `/up` for lightweight container liveness. The image entrypoint runs `bin/rails db:prepare`; a failed migration stops startup/deployment. Do not automatically run `db:rollback`. Inspect schema and migration state before correcting and retrying. Never edit files inside a running production container.

This repository does not create a large backup automatically in a deploy hook: backup storage availability and freshness are explicit operator prerequisites, and brittle hook behavior must not obstruct incident recovery.

The recurring operations queue removes expired SourceImports and unused workspace submissions hourly, clears finished queue records hourly, reconciles stale work, and removes only unattached Active Storage blobs older than seven days once daily. Structured application events are emitted to standard output; configure a bounded retention policy in the deployment log collector because the application does not own external log storage.

## Post-deploy

Run the credential-free endpoint and dependency smoke command from the deployed runtime:

```sh
bin/ops/post-deploy-smoke https://APP_HOST_PLACEHOLDER
```

Then verify `/up`, `/ready`, the admin-only aggregate Operations diagnostics, Solid Queue processing and recurring schedules, and structured one-line JSON events. Exercise an authenticated no-provider workflow if incident policy permits. Do not automatically submit source content, enqueue paid work, or call OpenRouter as a smoke test.

`/up` means process boot only. `/ready` means primary database web readiness only. Cache, cable, queue, and storage state belong to preflight, smoke, admin diagnostics, and logs so an auxiliary outage does not silently change load-balancer semantics.

Health probes and Host authorization:

- **Kamal Proxy liveness:** `/up` is exempt from Host authorization, because Kamal Proxy reaches the container by address.
- **Public readiness:** probe with Host `APP_HOST`, for example `bin/ops/post-deploy-smoke https://APP_HOST_PLACEHOLDER`.
- **Internal readiness:** probe from inside the container over loopback, for example `docker exec CONTAINER_PLACEHOLDER curl -fsS http://127.0.0.1:3000/ready`. Only `localhost`, `127.0.0.1`, and `[::1]` are accepted as Host for this.
- **Refused hosts:** any other Host, such as a container IP or an unknown name, receives `403` on `/ready` and on every application path. Probing `/ready` through a container IP therefore reports `403` by design.
- **Pre-promotion checks:** a quiescent or pre-promotion environment must be checked with the loopback probe, or with an explicit `Host: APP_HOST` header.

## Rollback

A code rollback and a database rollback are different operations.

```sh
bin/kamal rollback RELEASE_VERSION_PLACEHOLDER
```

Kamal can select an earlier application image; it does not reverse migrations. Roll back code only when the earlier code is compatible with the current schema. Never automatically run `db:rollback` in production. If schema state is uncertain, stop, inspect `bin/rails db:migrate:status`, review the exact migration transaction outcome, and choose a forward fix or separately reviewed database recovery procedure. Restoring a backup is disaster recovery with potential data loss, not a routine code rollback.
