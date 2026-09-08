# Three Heavens

Three Heavens is a Rails 8.1 application for authenticated, owner-scoped AI translation experiments, blind review, judge aggregation, and final translation refinement. PostgreSQL 17 is the source of truth; Solid Queue, Solid Cache, and Solid Cable use dedicated PostgreSQL databases in production.

## Automatic translation pipelines

Workflow Profiles are private, reusable configurations for translator, reviewer, judge, and optional finalizer models. Each edit appends an immutable revision with model-routing snapshots and a deterministic SHA-256 configuration digest; historical revisions are never rewritten.

The translation workspace remains manual by default. In automatic mode, the owner selects the exact current profile revision and explicitly confirms the configured initial provider run slots for that launch. This authorization covers automatic translation, blind review, judging, creation of the official winner draft, and—only in `refinement_proposals` mode—creation of AI refinement proposals. `winner_draft` stops after creating the draft. Both modes stop at the human editorial checkpoint: proposals are never applied, draft content is never changed, and a translation is never finalized automatically.

Every manual or automatic workspace form carries an owner-scoped, one-time opaque submission identity. Replaying or concurrently submitting the same form returns its existing experiment or pipeline without scheduling duplicate provider work. Invalid forms remain retryable with the same identity; unused identities expire after 24 hours and are removed in bounded cleanup batches.

Automatic progression can incur provider cost, and built-in bounded provider retries may add requests. Terminal failures block the pipeline and retain the existing explicit owner retry controls; a successful retry lets the already-authorized pipeline continue. Stopping automation prevents future stages but cannot cancel provider work already queued or running, removes no history, and does not prevent manual continuation.

`PipelineReconciliationJob` scans a bounded indexed batch every 10 minutes in production to recover missed advancement after queue failures, crashes, or restarts. A dedicated least-recently-reconciled cursor and row locks prevent permanently blocked pipelines from starving newer work. It processes only running or blocked automatic pipelines and never manual, stopped, or ready-for-editor workflows. This is intentionally separate from the provider-free stale-AI watchdog. Operators may invoke the same safe bounded service with `bin/rails pipelines:reconcile`; output contains aggregate counts only.

## Long-document execution and context safety

Documents remain authoritative whole source records up to 100,000 characters. When a source exceeds the single-request target, Three Heavens derives an immutable, versioned sequence of lossless segments using paragraph, line, sentence-like punctuation, and finally Unicode-safe hard boundaries. Rejoining the ordered segment text reproduces the reviewed source exactly; segmentation never replaces or rewrites it.

Translation, blind review, judging, and optional refinement then run one bounded provider request per logical model and source segment. The existing parent runs remain the candidate/reviewer/judge/finalizer records used by history, benchmarks, winner selection, and pipeline advancement. Their child segment runs are the physical provider calls, retain execution lineage and detailed telemetry, and retry only failed work. Parent cost is the sum of known child cost without counting child rows again in analytics; token completeness remains explicitly unknown if any child value is missing.

Administrators configure each model's context-window and maximum-output token capabilities in Settings / Models. Each scheduled provider call stores the capability snapshot and a deterministic `serialized-utf8-bytes-v2` estimate based on the fully serialized request: approximately one estimated token per UTF-8 byte plus framing allowance, the response schema, a stage output reserve, and a separate 1,024-token safety margin. This is intentionally conservative and is not claimed to match any provider tokenizer exactly. Existing unconfigured models retain a conservative 16,384/4,096-token fallback only for sources of at most 8,000 characters; long-document planning fails before provider work when capabilities are absent or insufficient.

OpenRouter account or organization configuration must not force the context-compression plugin in a way that prevents per-request overrides, because Three Heavens disables it for fidelity-critical workflows.

Every request sends an explicit stage completion limit, and provider responses are streamed through a 1 MiB byte ceiling before JSON parsing or persistence. Segment translations/refinements are limited to 20,000 characters and assembled documents remain limited to 100,000 characters; no output is silently truncated. Automatic pipeline authorization records the segment multiplier and exact initial provider-request slots (logical models × segments) for every stage. Built-in retries may add calls, so this is not a maximum HTTP request count.

Review scores are aggregated by source-character-weighted means. Each judge uses source-character-weighted segment Borda points, then weighted mean score and stable TranslationRun ID tie-breaking; the existing cross-judge Borda aggregate still selects one official logical candidate only after every required judge completes. Refinement proposals are reassembled but remain unapplied until the human editor chooses Apply Proposal. A manual edit deliberately invalidates segment alignment for further segmented AI refinement; manual editing, restoration, finalization, and export remain available. Historical non-segmented experiments continue to render without fabricated segment history, and benchmark translation/win counts remain logical candidate counts rather than physical segment-call counts.

These controls bound requests; they do not guarantee that every 100,000-character document fits every selected model or configuration. Unsupported plans fail safely before the affected stage schedules provider work.

## Development workflow

`develop` is the default integration branch. Normal Codex work starts from
current `develop` on a focused task branch, and each task branch opens a Pull
Request back to `develop`. Codex may autonomously merge a task Pull Request after
its required checks pass. `main` is reserved for human-controlled releases:
Codex never merges into `main`, and the final `develop` to `main` release occurs
only after external and human audit.

## Local development

Install Ruby 3.4.10 and PostgreSQL 17, then install gems with `bundle install`. The included `compose.yml` runs PostgreSQL on the loopback interface. Local Rails configuration expects these environment variable names:

- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_PORT`
- optional `DB_HOST`
- `OPENROUTER_API_KEY` only when a person explicitly starts real AI work

Create and migrate the databases with:

```sh
bin/rails db:prepare
```

The PostgreSQL Docker volume contains persistent development data. Never run `docker compose down -v` unless intentionally destroying that local database.

Create or promote the first administrator without placing a password in shell history:

```sh
bin/rails accounts:bootstrap_admin
```

The task prompts securely for the required account data.

## Recoverable AI workflows

Every scheduling cycle persists the intended Active Job `job_id`, a pending timestamp, and the last claimed execution number before the job is enqueued. The first execution and strictly newer built-in retries from that same job lineage may claim; duplicate executions, different jobs, and obsolete retries from an earlier manual-recovery cycle are harmless. Every accepted claim records a new execution attempt and refreshes `last_claimed_at`; the original `started_at` remains the first-start analytics timestamp. A late result can only update the exact attempt that claimed the run.

Provider-run state commits to the primary database before enqueueing against the separate queue database. The actual adapter enqueue runs inside an `after_all_transactions_commit` callback, including when a workflow service is nested inside a wider application transaction; with no open transaction, that callback runs synchronously. A definite Solid Queue enqueue failure or Active Job false result is converted to the generic `enqueue_failed` state and reconciled; unexpected programming exceptions propagate, and raw queue/database errors are never stored. Successfully queued siblings remain valid.

Production schedules `StaleAiWorkReconciliationJob` every 15 minutes through Solid Queue. Pending work that has not begun, or running work without a fresh claim, for 120 minutes is marked failed with the generic `stale_pending` or `stale_execution` code and its parent is reconciled. This closes the crash window between the primary commit and queue enqueue. A delayed job arriving after recovery is obsolete and cannot issue a provider request. Set `AI_STALE_EXECUTION_THRESHOLD_MINUTES` to an operator-chosen value from 15 through 1440 minutes. This server setting is never browser input.

The watchdog never issues a provider request. Owners explicitly retry failed work from the workflow page, where the additional request/cost warning is shown. Completed siblings, stable run identities, anonymous mappings, and finalization base versions are preserved.

An operator can run the same bounded, idempotent reconciliation manually:

```sh
bin/rails ai:reconcile_stale
```

With `SOLID_QUEUE_IN_PUMA=true`, the production Puma process supervises Solid Queue and its recurring schedule. Larger installations should use a dedicated `bin/jobs` role while keeping exactly one deliberate recurring-job topology.

## Secure document import and export

Authenticated owners may paste source text or upload `.txt`, `.md`, and `.docx` source files. Legacy `.doc`, `.docm`, RTF, HTML, ODT, PDF, images, and directly supplied archives are intentionally unsupported. PDF parsing and OCR require a separate security and product design.

Uploads are limited by the application to 10 MiB, and normalized extracted text is limited to `Ai::UsageLimits::MAX_SOURCE_CHARACTERS` (currently 100,000 characters). Kamal Proxy accepts request bodies up to 12 MiB so a 10 MiB upload plus multipart framing can reach the authoritative application check. Sanitized original filenames are limited to 255 Unicode characters while preserving their extension. TXT and Markdown must be valid UTF-8; an optional UTF-8 BOM is removed and line endings become LF. Markdown remains plain source text and is never rendered as trusted HTML.

DOCX processing uses a bounded ZIP reader in memory. It requires the normal OOXML package entries, rejects encrypted or macro-enabled packages, traversal-style names, excessive entry counts, excessive declared expansion, large relevant XML, and suspicious compression ratios. XML parsing is strict and network-disabled; V1 reads visible body paragraphs, runs, tabs, explicit breaks, and tables. It does not recreate Word layout, fetch relationships, extract images, execute macros, or perform OCR.

Upload and extraction create an owner-scoped `SourceImport` staging record. The owner reviews and may edit extracted text in the normal translation workspace. Upload, parsing, preview, cancellation, cleanup, and export never enqueue or call an AI provider. A successful workspace submission locks and consumes an import once, atomically creates the normal Project/Document/Experiment graph, records immutable source text and provenance, and reuses the Active Storage blob for the Document without copying file bytes.

Original uploads are private. Downloads pass application owner authorization, use attachment disposition, and never expose a permanent blob URL. Abandoned imports expire after 24 hours; production runs bounded cleanup hourly. Destroying an abandoned import synchronously purges its bounded local file after the database transaction commits, without relying on a purge-job enqueue. A blob shared by a consumed Document remains protected by its attachment. An operator may safely process one bounded batch manually:

```sh
bin/rails source_imports:cleanup
```

Final translation owners can download the current draft or finalized version as exact UTF-8 TXT or a minimal real macro-free OOXML DOCX. Exports are generated on demand and are not stored.

## Health endpoints

- `/up` is lightweight process liveness: Rails successfully booted.
- `/ready` is web readiness: the primary database accepts a minimal `SELECT 1`.

Readiness returns only `ready` or `unavailable`; it never calls OpenRouter or exposes database errors. The primary database is the readiness contract because every authenticated web workflow depends on it, while queue/cache/cable degradation is separately visible to operators and does not necessarily make basic web serving unsafe.

## Production operations

The authoritative recovery set is the primary PostgreSQL database plus private Active Storage files. Cache and cable are rebuildable; the queue database is rebuilt empty during disaster recovery so old paid-work jobs are not blindly replayed. Create a versioned checksum-protected bundle with `bin/ops/backup /absolute/backup-root`, verify an isolated restore with `RESTORE_DATABASE_URL` and `RESTORE_STORAGE_PATH` plus `bin/ops/restore-verify BUNDLE_PATH`, and preview/execute local completed-bundle retention with `bin/ops/backup-prune`.

Run `bin/ops/preflight` before deployment and `bin/ops/post-deploy-smoke https://APP_HOST_PLACEHOLDER` afterward. Operational events are fixed-schema one-line JSON on the normal Rails logger; arbitrary metadata and private content are rejected. `/up` remains process liveness, `/ready` remains primary-database readiness, and the admin-only Operations page reports generic aggregate dependency diagnostics. No health, preflight, restore, or smoke command calls OpenRouter automatically.

Detailed executable procedures are in:

- [Backup and restore](docs/operations/backup-and-restore.md)
- [Disaster recovery](docs/operations/disaster-recovery.md)
- [Production deployment and rollback](docs/operations/production-deploy.md)

## Production configuration

Production fails fast when its public host or database URLs are missing. Required runtime secret variable names are:

- `RAILS_MASTER_KEY`
- `DATABASE_URL`
- `CACHE_DATABASE_URL`
- `QUEUE_DATABASE_URL`
- `CABLE_DATABASE_URL`
- `OPENROUTER_API_KEY`

Required non-secret runtime variable names are:

- `APP_HOST`
- optional `RAILS_LOG_LEVEL`
- optional `RAILS_MAX_THREADS`
- optional `JOB_CONCURRENCY`
- optional `AI_STALE_EXECUTION_THRESHOLD_MINUTES`

The four database URLs must point to distinct PostgreSQL databases or otherwise deliberately isolated databases for these roles:

- primary application records and migrations;
- Solid Cache (`db/cache_schema.rb`, migrations path `db/cache_migrate`);
- Solid Queue (`db/queue_schema.rb`, migrations path `db/queue_migrate`);
- Solid Cable (`db/cable_schema.rb`, migrations path `db/cable_migrate`).

Production assumes TLS terminates at the trusted Kamal proxy, forces HTTPS for browser traffic, uses secure cookies and HSTS, and authorizes only `APP_HOST` for normal requests. Kamal-proxy checks the target container with its internal target-style Host, so only the lightweight `/up` liveness endpoint is excluded from Host Authorization. `/ready` remains Host-authorized. Both health endpoints may be checked directly inside the private container network without an HTTPS redirect. Do not expose PostgreSQL publicly; place it on a private network or bind any accessory port to loopback only.

Asset precompilation supports `SECRET_KEY_BASE_DUMMY=1` and does not require real secrets or a live database. That build-only flag must not be used for a running production server.

Active Storage production files use the local `/rails/storage` path, backed by the named `three_heavens_storage` Kamal volume. The volume is not served as a public directory and survives application-container replacement. The image runs as uid/gid 1000, so the mounted storage volume must remain writable by that identity. Do not bake uploads into an image. Production backup and recovery cover the authoritative primary PostgreSQL database and the persistent storage volume; cache and cable are recreated, and queue state follows the documented no-stale-replay recovery policy.

## Kamal prerequisites

`config/deploy.yml` contains no example destination and fails fast until operators supply:

- `KAMAL_WEB_HOST`
- `APP_HOST`
- `KAMAL_IMAGE` (the repository name/path within the registry, without the registry hostname)
- `KAMAL_REGISTRY_SERVER`
- `KAMAL_REGISTRY_USERNAME`
- secret `KAMAL_REGISTRY_PASSWORD`
- every runtime secret name listed above

Populate Kamal secrets through the operator's approved secret manager or local Kamal secret mechanism; never commit their values. The image continues to run as the non-root `rails` user. Confirm DNS, firewall rules, TLS issuance, database backups, and all four database URLs before the first deploy.

## Validation

The complete local quality gate is:

```sh
bin/rails db:migrate
bin/rails db:migrate:status
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
git diff --check
bin/rails zeitwerk:check
```

Tests use deterministic fakes and Active Job's test adapter. They require PostgreSQL and a local Chrome/Chromium browser for system tests, but never require `OPENROUTER_API_KEY` and never make a real provider request.

## Supply-chain maintenance

CI actions use verified release commit SHAs with version comments, maintained by
weekly grouped GitHub Actions Dependabot updates. Bundler updates remain weekly
and separate. Update the setup-ruby pin when adopting a Ruby version newer than
that action release. CI grants only `contents: read` and does not persist checkout
credentials. Keep `pull_request` execution and all five fail-closed jobs.

The Dockerfile base, Dockerfile frontend, and both CI PostgreSQL services use
official multi-architecture index digests resolved from Docker Hub. Before each
release, review upstream security updates and refresh these digests with
`docker buildx imagetools inspect <image:tag>`; use the top-level digest, retaining
the readable tag. Update both PostgreSQL services together. These image pins
require manual review; the configured Dependabot ecosystems maintain actions and
gems. Validate a bounded production build and all five CI jobs after updates.
Pinning the frontend also stabilizes build checks under `check=error=true`.
Debian packages remain unpinned to receive repository security fixes, so builds
are not claimed to be bit-for-bit reproducible. Kamal still builds for amd64.

RuboCop caches contain lint results, and setup-ruby caches installed gems keyed
by runtime and lockfile. Neither cache should contain secrets. GitHub's branch
and pull-request cache scopes prevent caches written by a pull request from
being restored by the base branch; keep this workflow free of privileged
`pull_request_target` or `workflow_run` execution of pull-request code.
