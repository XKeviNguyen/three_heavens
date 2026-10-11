# V1 final readiness record

This record covers the last V1 feature milestone: guided product tours, the translation reference upload experience, retry payer labels, and related fixes. It sits on top of the OpenRouter bring-your-own-key (BYOK) release ([PR #90](https://github.com/XKeviNguyen/three_heavens/pull/90)), which is merged into `develop`.

Nothing here is released, tagged, or deployed. Merging, releasing, tagging, and deploying each need explicit human approval.

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

## Evidence levels

| Level | Status |
| --- | --- |
| Implemented | Yes, in the milestone pull request against `develop`. |
| Unit and integration tested | `ProductTour` (registry integrity, translations, first-resolution-wins), the migration backfill, `PATCH /product_tour` (auth, CSRF, other accounts, malformed and outdated input), retry payer guard (managed, personal key stamping, stale and missing payer, denied users), and the AI settings repeat fix (written failing first). |
| Browser verified | Headless Chrome system tests: invitation, Next/Back/Skip/Finish, Escape, persistence, replay, page tours, a target removed mid-tour, Back/Forward, phone width in Japanese, 200% zoom in Vietnamese, both file fields, refused files, drops, and the no-JavaScript reference form. Screenshots were checked in light, dark, and mobile layouts. |
| CI verified | Recorded on the pull request for its exact final head SHA (all five jobs: `scan_ruby`, `scan_js`, `lint`, `test`, `system-test`). |
| Production verified | **No.** Nothing has been deployed. |

## Open items that remain release concerns

- **[PR #87](https://github.com/XKeviNguyen/three_heavens/pull/87) — Cloudflare Tunnel client IP trust and throttling.** Open and separately reviewed. Green CI on this milestone does not resolve it. Rate limits that key on client IP depend on its outcome in the deployed topology.
- **[PR #86](https://github.com/XKeviNguyen/three_heavens/pull/86) — obsolete proprietary licensing language.** Open and stale. The repository is MIT licensed; PR #86 must not be merged as it is.
- **BYOK production cutover.** PR #90's billing migrations fence out pre-BYOK code (see [production deploy and rollback](../operations/production-deploy.md#rollback)). The first deploy fails AI starts on the old container until traffic switches, and an image rollback past that release leaves AI starts failing closed; roll forward instead. CI does not prove migration timing or live billing behavior on production data.
- **Production configuration.** Proxy, tunnel, TLS, host networking, databases, and secrets were not changed by this milestone and are not verified by it.
- **Tours on refreshing pages.** Pages that reload every 5 seconds while AI work runs (results, blind review, judging, automatic workflow progress) do not start tours or show the invitation until the work finishes.
- **No-JavaScript language selection.** The language combobox on reference and workspace forms needs JavaScript to submit a language (a pre-existing limitation, not introduced here). The reference file inputs themselves work without JavaScript.

## Operational notes for this milestone

- Migration `20261011090000` adds two nullable `users` columns, backfills every existing row as `preexisting`, and adds a CHECK constraint, under `lock_timeout = 1s`. `users` holds one row per account, so this is brief. Code from before this milestone ignores the columns; an account it creates during the deploy starts unresolved and is offered the tour, which is correct for a new account.
- Rolling the code back leaves the columns unused and harmless. Do not roll the migration back in production; it would discard recorded tour outcomes.
- The islands bundle now loads on every signed-in page: 245.7 KiB minified and 76.0 KiB gzipped, up from 227.0 KiB and 70.4 KiB (+18.7 KiB, +5.6 KiB gzipped). No dependency was added. It is an ES module served by Propshaft with a digest, so browsers cache it.
- The tour sends at most one request per offered version (`PATCH /product_tour`, rate limited per user). Tooltip steps send nothing. If that request fails (offline, signed out, refused), the invitation hides on the current page only and is offered again on the next one.

## Recommended release approach

1. Human: audit the milestone pull request at its exact head SHA, then decide whether to merge into `develop`.
2. After a merge: verify the post-merge `develop` CI run (all five jobs) on its exact SHA.
3. Resolve or explicitly defer PR #87 with a documented decision; close PR #86 without merging.
4. Human: approve the `develop` → `main` release pull request after its own CI and audit.
5. Human: approve the production deploy at a quiet time, following the BYOK cutover notes; back up first ([backup and restore](../operations/backup-and-restore.md)).
6. After deploy: run the post-deploy smoke test, confirm `/ready`, check that an existing account sees no invitation and a new account sees one, and confirm one AI start per payment source with a deliberately authorized request.
7. Human: tag and publish the release only after step 6 passes.
