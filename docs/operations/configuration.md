# Production configuration

Operator reference for environment variables, Kamal prerequisites, maintenance tasks, and supply-chain upkeep. Step-by-step procedures are in [production deploy and rollback](production-deploy.md), [backup and restore](backup-and-restore.md), and [disaster recovery](disaster-recovery.md).

## Local development variables

Development and test read these names (through `dotenv-rails` from an untracked `.env`):

- `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_PORT`, optional `DB_HOST`
- `OPENROUTER_API_KEY` — only when a person explicitly starts real AI work; tests never need it
- optional `GOOGLE_CLIENT_ID` — public OAuth client ID for Sign in with Google (no client secret); see [Google sign-in](../identity/google-sign-in.md)

The `compose.yml` PostgreSQL service binds to the loopback interface. Its volume holds persistent development data; never run `docker compose down -v` unless you intend to delete that database.

Create or promote the first administrator with `bin/rails accounts:bootstrap_admin`. From an interactive terminal it prompts for the email and reads the password and confirmation without echo. For automation, set `THREE_HEAVENS_ADMIN_EMAIL` and `THREE_HEAVENS_ADMIN_PASSWORD` through the process environment or a secret manager; a non-interactive run without both fails instead of waiting. Never put the literal password on a command line.

## Production variables

Production fails fast, before serving any request, when its public host, database URLs, or mail settings are missing.

Secrets:

- `RAILS_MASTER_KEY`
- `DATABASE_URL`, `CACHE_DATABASE_URL`, `QUEUE_DATABASE_URL`, `CABLE_DATABASE_URL`
- `OPENROUTER_API_KEY`
- `SMTP_USERNAME`, `SMTP_PASSWORD`

Non-secret:

- `APP_HOST`
- `MAIL_FROM` (for example `Three Heavens <no-reply@APP_HOST_PLACEHOLDER>`)
- `SMTP_HOST`; optional `SMTP_PORT` (default 587). Port 465 uses implicit TLS; every other port must offer STARTTLS, and delivery fails rather than sending credentials unencrypted.
- `GOOGLE_CLIENT_ID` — the production Web OAuth client ID. The app only hides Google sign-in without it, but `bin/ops/preflight` fails its `google_client_id` check, so a V1.1 deployment requires it.
- optional `RAILS_LOG_LEVEL`, `RAILS_MAX_THREADS`, `JOB_CONCURRENCY`, `AI_STALE_EXECUTION_THRESHOLD_MINUTES` (15–1440, server-only)

The four database URLs must point to distinct or deliberately isolated databases:

| Role | Schema |
| --- | --- |
| Primary application data | `db/structure.sql` (migrations in `db/migrate`) |
| Solid Cache | `db/cache_schema.rb` |
| Solid Queue | `db/queue_schema.rb` |
| Solid Cable | `db/cable_schema.rb` |

`config/database.yml` names `db/cache_migrate`, `db/queue_migrate`, and `db/cable_migrate` as their migration paths; those directories do not exist until a Solid gem upgrade adds migrations.

Asset precompilation supports `SECRET_KEY_BASE_DUMMY=1` and needs no real secrets or database. That build-only flag must never be used for a running server.

## TLS, hosts, and health checks

Production assumes TLS terminates at the trusted kamal-proxy, forces HTTPS, uses secure cookies and HSTS, and authorizes only `APP_HOST`. kamal-proxy checks the container with its internal Host, so only `/up` is excluded from Host Authorization. `/ready` stays Host-authorized: it answers through the proxy with Host `APP_HOST`, or inside the container on Puma's port 3000 over loopback with Host `localhost`, `127.0.0.1`, or `[::1]` (through Thruster's port 80 it returns 403). Neither endpoint redirects to HTTPS. Never expose PostgreSQL publicly.

## Storage

Active Storage uses the local `/rails/storage` path on the named `three_heavens_storage` Kamal volume. It is not served publicly and survives container replacement. The image runs as uid/gid 1000, so the volume must stay writable by that identity. Never bake uploads into an image.

## Jobs

With `SOLID_QUEUE_IN_PUMA=true` (set in `config/deploy.yml`), Puma supervises Solid Queue and its recurring schedule. Larger installations should use a dedicated `bin/jobs` role while keeping exactly one recurring-job topology.

## Kamal prerequisites

`config/deploy.yml` has no example destination and fails fast until operators supply:

- `KAMAL_WEB_HOST`, `APP_HOST`
- `KAMAL_IMAGE` (repository path within the registry, without the hostname), `KAMAL_REGISTRY_SERVER`, `KAMAL_REGISTRY_USERNAME`, secret `KAMAL_REGISTRY_PASSWORD`
- `MAIL_FROM`, `SMTP_HOST`, `GOOGLE_CLIENT_ID`, optional `SMTP_PORT` (passed as clear environment)
- every runtime secret above (passed as secret environment)

Populate secrets through an approved secret manager or the local Kamal secret mechanism; never commit values. A `$NAME` reference to an unset shell variable silently becomes empty, which production then refuses to boot with, so confirm each one resolves before deploying. `test/config/production_deployment_contract_test.rb` renders `config/deploy.yml` with dummy values and proves production boots from exactly that environment and refuses to boot without each required variable. Confirm DNS, firewall rules, TLS issuance, database backups, and all four database URLs before the first deploy.

Run `bin/ops/preflight` before a deploy and `bin/ops/post-deploy-smoke https://APP_HOST_PLACEHOLDER` afterward. None of the health, preflight, restore, or smoke commands calls OpenRouter.

## Maintenance tasks

All are bounded and safe to repeat:

```sh
bin/rails ai:reconcile_stale            # fail stuck AI work; never calls a provider
bin/rails pipelines:reconcile           # re-advance automatic workflows; aggregate output only
bin/rails source_imports:cleanup        # one bounded batch of expired uploads
bin/rails backend:cleanup_unattached_blobs                         # dry run
EXECUTE=1 bin/rails backend:cleanup_unattached_blobs               # after reviewing counts
BEFORE=2026-01-01T00:00:00Z bin/rails backend:remediate_legacy_errors   # dry run by default
```

The legacy-error task examines only failed AI runs before the cutoff, never prints stored error content, replaces at most 100 rows per run by default (`BATCH_SIZE` up to 1,000) with a fixed safe message, and is idempotent. Production log retention belongs to the log collector, not to deleting durable records.

## Backups

The authoritative recovery set is the primary PostgreSQL database plus the storage volume. Cache and cable are rebuildable; the queue is rebuilt empty during disaster recovery so old paid-work jobs are not replayed. `bin/ops/backup /absolute/backup-root` creates a versioned, checksum-protected bundle; `bin/ops/restore-verify BUNDLE_PATH` (with `RESTORE_DATABASE_URL` and `RESTORE_STORAGE_PATH`) verifies an isolated restore; `bin/ops/backup-prune` previews and executes local retention.

## Supply-chain maintenance

CI actions use verified release commit SHAs with version comments, maintained by weekly grouped Dependabot updates; Bundler updates are weekly and separate. Update the setup-ruby pin when adopting a newer Ruby. CI grants only `contents: read` and does not persist checkout credentials. Keep `pull_request` execution and all five fail-closed jobs.

The Dockerfile base and frontend images and both CI PostgreSQL services use official multi-architecture index digests. Before each release, review upstream security updates and refresh them with `docker buildx imagetools inspect <image:tag>`, using the top-level digest and keeping the readable tag. Update both PostgreSQL services together, then validate a production build and all five CI jobs. Debian packages stay unpinned to receive security fixes, so builds are not claimed to be bit-for-bit reproducible. Kamal builds for amd64.

RuboCop caches and setup-ruby gem caches must not contain secrets. GitHub's cache scopes prevent pull-request caches from being restored by the base branch; keep the workflow free of privileged `pull_request_target` or `workflow_run` execution of pull-request code.

## Validation gate

`bin/ci` (defined in `config/ci.rb`) runs RuboCop, whitespace (`git diff --check` against the empty tree), bundler-audit, importmap audit, Brakeman (`--ensure-latest`), Zeitwerk, migration status with a pending-migration check, and the unit, integration, and system tests. Run `bin/rails db:migrate` first when a branch adds a migration. GitHub Actions runs the same checks, except the local-only migration-status steps, as `scan_ruby`, `scan_js`, `lint`, `test`, and `system-test`; `test/config/ci_gate_test.rb` fails if `config/ci.rb` gains a check no CI job runs.
