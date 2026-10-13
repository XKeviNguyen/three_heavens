# V1 final readiness record

This record covers the last V1 feature milestone: guided product tours, the translation reference upload experience, retry payer labels, and related fixes. It sits on top of the OpenRouter bring-your-own-key (BYOK) release ([PR #90](https://github.com/XKeviNguyen/three_heavens/pull/90)), which is merged into `develop`.

Nothing here is released, tagged, or deployed. Merging, releasing, tagging, and deploying each need explicit human approval.

## Release status

The code release (`develop` → `main`) and the production release are separate. Green CI proves only the first.

| Item | Status |
| --- | --- |
| Features | Complete on `develop`: PRs #90, #91, #96, #97, #98 and the test-only #99. |
| CI | All five jobs pass on each pull request's exact head and on `develop`'s post-merge head. The `develop` → `main` release pull request records its own run. |
| Migration inventory | Seven migrations are pending against production (v1.1.0); see [migrations pending in production](#migrations-pending-in-production). |
| Production host evidence | Read-only inspection only. Gate B is not passed; host findings are kept in the operator's private audit record, not in this repository. |
| Backup and recovery proof | Not done. No encrypted off-host production backup has been restored and decrypted yet (gates B2 and B3). |
| Network isolation | Not proven from an independent test point (gate B1). |
| Human approval | Pending for the `main` merge, each production gate, the deploy, and the tag. |
| Deployed SHA | None. Production still runs v1.1.0 (`15459c2`). |

## What this milestone adds

| Area | Behavior | Main code |
| --- | --- | --- |
| Global product tour | Seven steps: welcome, workspace, translation knowledge, workflow setups, AI access and who pays, starting a translation, and from candidates to a final translation. New accounts get a one-time, non-blocking invitation; accounts that existed before this release are never invited. | `ProductTour`, `app/frontend/islands/product_tour/` |
| Page tours | One registry entry per feature family: New translation, source upload, Projects, History, Glossaries, References, Methodology, Workflow setups and pipeline runs, AI settings, Translation results, Blind review, Judging, Final editor, Benchmarks. Missing or hidden elements are skipped. | `ProductTour::PAGE_TOURS`, `data-tour-target` attributes |
| Help | **Help → Full product tour** and **Help → Tour this page**, available after completing or skipping. | `ProductTour.tsx` |
| Onboarding state | `users.product_tour_version` and `users.product_tour_outcome`, written once per version by a conditional `UPDATE` (`PATCH /product_tour`); existing accounts are backfilled as `preexisting`. | migration `20261011090000` |
| Reference uploads | Both reference file inputs: choose, replace, remove, drag and drop, name and size, format and size feedback, a warning when text is pasted too. The native input still submits with the Rails form. | `FileField.tsx`, `FileFieldHelper` |
| Retry payer | Each explicit retry (translation, blind review, judging, suggestions) shows who will pay, including which of the user's keys by its last characters, and posts that payer back; the retry is refused, with nothing queued, if the source or the key changed after the page was shown. The comparison and the stamping of the runs happen under the owner's row lock (`Ai::BillingPolicy.authorize_confirmed!`), so a concurrent payment change lands before the check or after the stamp. | `AiBillingHelper#retry_payer`, `Ai::BillingPolicy.authorize_confirmed!`, `ApplicationController#retry_under_shown_payer` |
| AI settings fix | Without JavaScript, a double submit or a resubmit after Back reported "changed in another window" although the change had been applied. A stale payment-source or delete request is now accepted when the current state already equals what it asks for (and the source is usable). A repeated key save still reports a conflict, because recognizing it would mean decrypting the stored key in a web request; the first save is kept exactly once. | `Accounts::AiSettings.change` |
| Reference edits | On the edit form, unchanged prefilled text no longer triggers the "text and a file" warning when a replacement file is chosen. The server's replacement of unchanged prefilled text now compares line endings normalized, so multi-line text (submitted by browsers with CRLF) is replaced as the page promises instead of being rejected as "not both". | `TranslationReference#prefilled_text?`, `FileField.tsx` |
| API key field | Password-manager hints (`data-1p-ignore`, `data-lpignore`, `data-bwignore`, `data-form-type="other"`), `autocapitalize`/`autocorrect` off. These are hints; no browser or manager can be forced to ignore a field. | AI settings view and island |

Deliberately unchanged: billing authorization and retry semantics (a retry is still authorized under the owner's current selection), accepted file types and size limits, server-side extraction, automatic OpenRouter key verification (not added), deletion of revoked credential rows (not done), the TypeScript toolchain, and the New translation upload, whose Stimulus upload/ownership flow is already covered by its own replay tests and was not replaced.

New AI work is authorized once, when it starts (an automatic workflow at launch, and each later stage re-checks that launch authorization). The New translation form authorizes and stamps under one lock. Starting review, judging, or finalization authorizes just before stamping, so a payment change committing in between applies to the next start; that matches "records who paid when it started" in the [user guide](../user-guide.md#ai-settings-and-who-pays), and a key or managed permission withdrawn meanwhile fails the work closed at its claim, never on the platform key. `test/jobs/byok_job_billing_test.rb` covers that outcome, and `test/services/pipelines/advance_test.rb` covers later automatic stages keeping, or blocking on, the launch payer. Accepted difference from retries: the New translation page shows the current payment source but does not post it back, so a page left open while the source is changed in another tab starts work under the newer choice instead of refusing; confirming the shown payer there, as retries do, is a possible follow-up.

## Evidence levels

| Level | Status |
| --- | --- |
| Implemented | Yes, in the milestone pull request against `develop`. |
| Unit and integration tested | `ProductTour` (registry integrity, translations, first-resolution-wins), the migration backfill, `PATCH /product_tour` (auth, CSRF, other accounts, malformed and outdated input), retry payer guard (managed, personal key stamping, stale and missing payer, denied users), and the AI settings repeat fix (written failing first). |
| Browser verified | Headless Chrome system tests: invitation, Next/Back/Skip/Finish, Escape, persistence, replay, page tours, a target removed mid-tour, Back/Forward, phone width in Japanese, 200% zoom in Vietnamese, both file fields, refused files, drops, and the no-JavaScript reference form. Screenshots were checked in light, dark, and mobile layouts. |
| CI verified | Recorded on the pull request for its exact final head SHA (all five jobs: `scan_ruby`, `scan_js`, `lint`, `test`, `system-test`). |
| Production verified | **No.** Nothing has been deployed. |

## Open items that remain release concerns

- **[PR #87](https://github.com/XKeviNguyen/three_heavens/pull/87) — Cloudflare Tunnel client IP trust and throttling.** Merged into `develop` at `75b3253`, whose post-merge CI passed all five jobs. It changes the deployment proxy configuration: `config/deploy.yml` now sets `ssl: false`, `forward_headers: true`, and `proxy.run.publish: false`, so kamal-proxy trusts X-Forwarded-For. That is safe only while cloudflared is the only route to kamal-proxy, which the production host must prove (gate B).
- **[PR #86](https://github.com/XKeviNguyen/three_heavens/pull/86) — obsolete proprietary licensing language.** Open and stale. The repository is MIT licensed; PR #86 must not be merged as it is.
- **BYOK production cutover.** PR #90's billing migrations fence out pre-BYOK code (see [production deploy and rollback](../operations/production-deploy.md#rollback)). The first deploy fails AI starts on the old container until traffic switches. An image rollback past that release leaves AI starts failing closed and stalls automatic workflow reconciliation, so roll forward only. CI does not prove migration timing or live billing behavior on production data.
- **Production network, firewall, and secrets.** Unverified. `proxy.run.publish: false` applies only when the kamal-proxy container is created, so a proxy created from v1.1.0's configuration (`ssl: true`, default port publishing) still publishes ports 80 and 443 after this deploy unless it is rebooted. The host firewall rule, cloudflared's route, Cloudflare's header settings, and the recoverability of the encryption root secrets can be verified only on the production host.
- **Welcome tours completed during the deploy.** While migrations run, the old container keeps serving. If it is a release that already has the welcome tour (for example `0af83e1`), a tour completed on it in that window is recorded without turning page guides on. Those accounts get the default for existing accounts: guides open only from Help, and the Help switch turns automatic guides on. This was accepted on purpose (PR #97) in preference to cross-release fallbacks.
- **Page guides claimed just before leaving.** Before a guide opens by itself, its page is claimed on the server, so it opens once across tabs and devices. If the user leaves the page, or another dialog opens, within that request's round-trip (typically under 100 ms), the claim still counts the guide as seen, and it does not open by itself later. It stays available from **Help → Guide to this page**. This was accepted on purpose (PR #97) in preference to a releasable claim.
- **Tours on refreshing pages.** Pages that reload every 5 seconds while AI work runs (results, blind review, judging, automatic workflow progress) do not start tours or show the invitation until the work finishes.
- **No-JavaScript language selection.** The language combobox on reference and workspace forms needs JavaScript to submit a language (a pre-existing limitation, not introduced here). The reference file inputs themselves work without JavaScript.

## Migrations pending in production

Every migration added since v1.1.0, applied in order by `db:prepare` while the new container boots. Each runs in its own transaction except `20261010090300`.

| Migration | Change | Locks and failure behavior |
| --- | --- | --- |
| `20261010090000_create_open_router_credentials` | New `open_router_credentials` table (encrypted keys), partial unique index, CHECK constraints. | The `user_id` foreign key takes SHARE ROW EXCLUSIVE on `users` until the migration commits, which waits for and blocks writes to `users`; `lock_timeout = 1s`, so a write to `users` held open for over a second fails the migration and the deploy, before the billing fence. Redeploy. |
| `20261010090100_add_ai_billing_identity` | `users.ai_payment_source`; `billing_source` and `open_router_credential_id` on the ten billed tables, with the constraints added `NOT VALID`; the default is removed again, which fences out pre-BYOK code; payer trigger on `ai_provider_attempts`. | ACCESS EXCLUSIVE locks on each table until the migration commits; `lock_timeout = 1s`. Roll forward only after it commits ([rollback](../operations/production-deploy.md#rollback)). |
| `20261010090200_validate_ai_billing_identity` | Validates those foreign keys and CHECK constraints. | SHARE UPDATE EXCLUSIVE while scanning; `lock_timeout = 10s`. |
| `20261010090300_index_ai_billing_credentials` | Partial `open_router_credential_id` indexes, built `CONCURRENTLY`. | No DDL transaction. Waits for older transactions. A retry drops and rebuilds an index left invalid. |
| `20261011090000_add_product_tour_state_to_users` | `users.product_tour_version` and `product_tour_outcome`; backfills every existing account as `preexisting`; CHECK constraint. | ACCESS EXCLUSIVE on `users` for the whole backfill; `lock_timeout = 1s`. |
| `20261012090000_create_product_tour_page_outcomes` | `users.product_tour_page_guides` (constant default, no rewrite); new `product_tour_page_outcomes` table with a unique index and CHECK constraints. | Brief ACCESS EXCLUSIVE on `users`; `lock_timeout = 1s`. |
| `20261012100000_add_product_tour_guides_revision_to_users` | `users.product_tour_guides_revision` (constant default) and a validated CHECK constraint. | ACCESS EXCLUSIVE on `users` while validating; `lock_timeout = 1s`. |

A failed transactional migration rolls back completely and is retried by the next deploy. No migration reads or rewrites encrypted columns.

Schema compatibility and availability differ during the deploy.

- **Schema:** every change is additive, so v1.1.0 code stays compatible with the new schema. Only the billing fence affects it, and that is intended.
- **Availability:** the old container keeps serving while the migrations run, and its requests wait on their locks. Every signed-in request reads `users`; `current_user` joins it with `sessions`.
  - While a migration holds ACCESS EXCLUSIVE on `users`, reads and writes there wait.
  - While it holds SHARE ROW EXCLUSIVE, only writes wait.
  - A migration still queued for its lock also blocks the requests behind it, for at most the 1-second `lock_timeout`.
  - The longest hold is the `20261011090000` backfill: 0.02 seconds at production size, 1.2 seconds at 100,000 `users` rows, and 13 to 17 seconds per million rows.

At production size the pause is well under a second, but requests do stall. Deploy at a quiet time.

Rehearsal on a disposable PostgreSQL 17 database loaded with the v1.1.0 schema at release candidate `b152d11` gave these results.

- **Production-sized data (2 accounts and one encrypted workspace draft):** all seven migrations took 0.49 seconds (2.0 seconds including Rails boot).
- **Integrity:** no invalid indexes and no unvalidated constraints. Existing accounts were backfilled as `preexisting`, with page guides off.
- **Encryption and retry:** the encrypted draft still decrypted, and a second migrate applied nothing.
- **Larger data:** the two page-guide migrations added 0.05 seconds at 100,000 `users` rows and 0.36 seconds at 1,000,000.

For timing at larger sizes, see pre-deploy step 8 in [production deploy](../operations/production-deploy.md#pre-deploy).

The development migration `20261012110000` existed only in intermediate PR #97 commits, and the PR removed it before merging. It is not in the release. A development database that ran it keeps a harmless orphan `schema_migrations` row.

## Operational notes for this milestone

- Migration `20261011090000` adds two nullable `users` columns, backfills every existing row as `preexisting`, and adds a CHECK constraint, under `lock_timeout = 1s`. `users` holds one row per account, so this is brief at the expected size; it holds an ACCESS EXCLUSIVE lock on `users` for the backfill, measured at about 17 seconds per million rows (see pre-deploy step 8 in [production deploy](../operations/production-deploy.md#pre-deploy)). Code from before this milestone ignores the columns; an account it creates during the deploy starts unresolved and is offered the tour, which is correct for a new account.
- Rolling the code back leaves the columns unused and harmless. Do not roll the migration back in production; it would discard recorded tour outcomes.
- The islands bundle now loads on every signed-in page: 245.7 KiB minified and 76.0 KiB gzipped, up from 227.0 KiB and 70.4 KiB (+18.7 KiB, +5.6 KiB gzipped). No dependency was added. It is an ES module served by Propshaft with a digest, so browsers cache it.
- The tour sends at most one request per offered version (`PATCH /product_tour`, rate limited per user). Tooltip steps send nothing. If that request fails (offline, signed out, refused), the invitation hides on the current page only and is offered again on the next one.

## Release gates

Each gate needs explicit human approval, and passing one never implies the next. Green CI covers gate A only.

**A. Code release approval (repository only).**

1. Verify the `develop` head's post-merge CI (all five jobs) on its exact SHA.
2. Close PR #86 without merging; it is not part of the release.
3. Human: audit and approve the `develop` → `main` release pull request after its own CI on its exact head SHA. Merge it with a merge commit, not squash or rebase, so `develop` stays an ancestor of `main`. Nothing deploys on a `main` merge: the repository has no deploy workflow, Actions secrets, webhooks, or environments.

**B. Production host gates (before any deploy, on the host, read-only first).**

1. Proxy and firewall, following pre-deploy step 11 of [production deploy](../operations/production-deploy.md#pre-deploy): kamal-proxy publishes no host port (if it does, confirm cloudflared reaches it over the `kamal` network and run `bin/kamal proxy reboot` before the deploy), cloudflared targets kamal-proxy on port 80, and the boot-persistent firewall rule is installed and proven by the probe from another machine with `tcpdump` evidence.
2. Encrypted off-host backup: a fresh `bin/ops/backup` bundle copied to approved encrypted off-host storage.
3. Actual restore proof: `bin/ops/restore-verify` of that bundle on disposable targets, plus the decryption check with the separately protected `RAILS_MASTER_KEY` ([encryption root secrets](../operations/backup-and-restore.md#encryption-root-secrets)).
4. Migration timing: row counts and long-running transactions checked against pre-deploy step 8.
5. `bin/ops/preflight` passes in the candidate runtime.

**C. BYOK cutover (deploy).** Human: approve `bin/kamal deploy` (no destination) at a quiet time. If the deploy fails after the billing migration commits, redeploy the same release promptly, after the `pg_stat_activity` check in the rollback section; never roll back the image or the migrations ([rollback](../operations/production-deploy.md#rollback)).

**D. Production smoke tests.** `bin/ops/post-deploy-smoke`, `/ready`, kamal-proxy shows no port binding and `forward_headers` true, the application log records a browser's public address for `/login`, an existing account sees no tour invitation and a new account sees one, and no failed Solid Queue jobs mention the run payer or `billing_source`. One AI start per payment source is a paid request and needs its own explicit authorization.

**E. Tag and publish.** Human: only after gate D passes.
