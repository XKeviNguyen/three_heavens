# Data dictionary

Every application table in the primary PostgreSQL database, grouped as in the [database diagrams](database.md). Keys, unique indexes, delete rules, and constraint counts are taken from `db/structure.sql` at V1.1; follow the schema link for column types and the exact CHECK and trigger definitions.

Delete rules not shown are PostgreSQL's default `NO ACTION`, which also refuses to delete a referenced row. A column ending in `_id` is a foreign key only where an FK is listed; polymorphic and logical links are described in the purpose.

## Accounts and sessions

### `users`

An account: email, optional password digest (Google-only accounts have none), role, status, interface language and appearance, and the per-account AI access switch.

- **Lifecycle:** Durable. Disabling an account deletes its sessions; the application has no account-deletion feature.
- **Keys:** PK `id` · UK `(lower((email)::text))`
- **Integrity:** 5 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L3452)

### `sessions`

One signed-in browser. The encrypted session cookie holds only this row's ID.

- **Lifecycle:** Deleted on sign-out or account disable; rows older than 30 days are purged hourly.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE CASCADE
- **Integrity:** 0 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L2924)

### `federated_identities`

Links an account to a Google subject (`provider_uid`). One link per provider per account, and one account per Google subject.

- **Lifecycle:** Created on connect, deleted on disconnect; cascades with the user.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE CASCADE · UK `(provider, provider_uid)` · UK `(user_id, provider)`
- **Integrity:** 2 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L1741)

### `consumed_nonces`

SHA-256 digests of Google sign-in nonces already used, so each nonce works once. Raw nonces are never stored.

- **Lifecycle:** Expires with the nonce.
- **Keys:** PK `id` · UK `(digest)`
- **Integrity:** 1 CHECK constraint, 0 triggers · [schema](../../db/structure.sql#L1516)

### `upload_budgets`

Per-account upload counter for the current fixed 5-minute window, with refund receipts so a failed upload is refunded at most once.

- **Lifecycle:** One row per account, rolled forward as windows change.
- **Keys:** PK `id` · FK `user_id` → `users(id)` · UK `(user_id)`
- **Integrity:** 2 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L3418)

## Source and translation

### `projects`

Groups documents that share one source and target language.

- **Lifecycle:** Durable.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE RESTRICT
- **Integrity:** 0 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L2656)

### `documents`

The authoritative source text and, for uploads, provenance (filename, detected type, size, SHA-256, extractor version). The original file is an Active Storage attachment.

- **Lifecycle:** Durable.
- **Keys:** PK `id` · FK `project_id` → `projects(id)`
- **Integrity:** 4 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L1587)

### `experiments`

UI: **Translation**. One source run against several candidates, with the instructions and the exact glossary and methodology revisions used.

- **Lifecycle:** Durable. Guidance links and guidance preference cannot be rewritten after creation.
- **Keys:** PK `id` · FK `glossary_revision_id` → `glossary_revisions(id)`, ON DELETE RESTRICT · FK `methodology_profile_revision_id` → `methodology_profile_revisions(id)`, ON DELETE RESTRICT · FK `document_id` → `documents(id)`
- **Integrity:** 1 CHECK constraint, 5 triggers · [schema](../../db/structure.sql#L1703)

### `translation_runs`

UI: **Translation candidate**. One model's full translation of the document, plus the [shared execution columns](database.md#shared-execution-columns).

- **Lifecycle:** Durable. Completed rows are sealed; a failed run can be retried by the owner.
- **Keys:** PK `id` · FK `experiment_id` → `experiments(id)` · FK `llm_model_id` → `llm_models(id)` · UK `(experiment_id, id)` · UK `(experiment_id, llm_model_id)`
- **Integrity:** 8 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L3160)

### `llm_models`

Model catalog entry: gateway and identifier for routing, display name, and the context-window and output limits used for planning.

- **Lifecycle:** Durable. Deactivated instead of deleted, so history keeps resolving.
- **Keys:** PK `id` · UK `(gateway, model_identifier)`
- **Integrity:** 4 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L2427)

## Blind review and judging

### `review_rounds`

The blind-review stage of a translation; at most one per translation.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `experiment_id` → `experiments(id)` · UK `(experiment_id)`
- **Integrity:** 1 CHECK constraint, 2 triggers · [schema](../../db/structure.sql#L2739)

### `review_runs`

One reviewer model in a review round, plus the shared execution columns.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `review_round_id` → `review_rounds(id)` · FK `reviewer_llm_model_id` → `llm_models(id)` · UK `(review_round_id, reviewer_llm_model_id)`
- **Integrity:** 14 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L2772)

### `review_evaluations`

One reviewer's scores and feedback for one candidate under an anonymous label: four criterion scores and an overall score (1–10), strengths, issues, corrections, and an optional suggested translation.

- **Lifecycle:** Durable; sealed with its run.
- **Keys:** PK `id` · FK `translation_run_id` → `translation_runs(id)` · FK `review_run_id` → `review_runs(id)` · UK `(review_run_id, anonymous_label)` · UK `(review_run_id, translation_run_id)`
- **Integrity:** 6 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L2691)

### `judge_rounds`

The judging stage of a review; stores the Borda aggregate and the official winner, which stays null until every judge has finished.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `winner_translation_run_id` → `translation_runs(id)` · FK `review_round_id` → `review_rounds(id)` · UK `(id, winner_translation_run_id)` · UK `(review_round_id)`
- **Integrity:** 3 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L2241)

### `judge_runs`

One judge model: its own pick, rationale, and confidence, plus the shared execution columns.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `judge_round_id` → `judge_rounds(id)` · FK `winner_translation_run_id` → `translation_runs(id)` · FK `judge_llm_model_id` → `llm_models(id)` · UK `(judge_round_id, judge_llm_model_id)`
- **Integrity:** 16 CHECK constraints, 4 triggers · [schema](../../db/structure.sql#L2279)

### `judge_evaluations`

One judge's rank and score (1–100) for one candidate, with rationale, strengths, and risks.

- **Lifecycle:** Durable; sealed with its run.
- **Keys:** PK `id` · FK `translation_run_id` → `translation_runs(id)` · FK `judge_run_id` → `judge_runs(id)` · UK `(judge_run_id, anonymous_label)` · UK `(judge_run_id, rank)` WHERE (rank IS NOT NULL) · UK `(judge_run_id, translation_run_id)`
- **Integrity:** 3 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L2200)

## Human editor and AI suggestions

### `final_translations`

The human editor for one judging round: the official winner it was seeded from, the current version, and draft/finalized status. `lock_version` gives optimistic locking.

- **Lifecycle:** Durable. Finalized and reopened only by the owner.
- **Keys:** PK `id` · FK `id, current_version_id` → `final_translation_versions(final_translation_id, id)` · FK `judge_round_id, source_winner_translation_run_id` → `judge_rounds(id, winner_translation_run_id)` · FK `experiment_id, source_winner_translation_run_id` → `translation_runs(experiment_id, id)` · FK `source_winner_translation_run_id` → `translation_runs(id)` · FK `experiment_id` → `experiments(id)` · FK `judge_round_id` → `judge_rounds(id)` · UK `(id, experiment_id)` · UK `(judge_round_id)`
- **Integrity:** 2 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L1852)

### `final_translation_versions`

Append-only text versions with a gapless number, origin (seed, manual, ai_applied, restored), optional change note, and the AI suggestion it came from.

- **Lifecycle:** Durable and immutable. Saving unchanged text does not create a version.
- **Keys:** PK `id` · FK `source_finalization_run_id` → `finalization_runs(id)` · FK `final_translation_id` → `final_translations(id)` · UK `(final_translation_id, id)` · UK `(final_translation_id, version_number)` · UK `(source_finalization_run_id)` WHERE (source_finalization_run_id IS NOT NULL)
- **Integrity:** 5 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L1810)

### `finalization_rounds`

UI: an **AI suggestion round** for one exact base version. At most one running round per final translation.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `final_translation_id, base_final_translation_version_id` → `final_translation_versions(final_translation_id, id)` · FK `base_final_translation_version_id` → `final_translation_versions(id)` · FK `final_translation_id` → `final_translations(id)` · UK `(final_translation_id)` WHERE ((status)::text = 'running'::text)
- **Integrity:** 2 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L1891)

### `finalization_runs`

UI: one **AI suggestion**: proposed text, change summary, terminology notes, and warnings, plus the shared execution columns.

- **Lifecycle:** Durable; sealed once completed. Applied at most once.
- **Keys:** PK `id` · FK `finalization_round_id` → `finalization_rounds(id)` · FK `finalizer_llm_model_id` → `llm_models(id)` · UK `(finalization_round_id, finalizer_llm_model_id)`
- **Integrity:** 18 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L1927)

## Long documents

### `document_execution_plans`

How a long source was split: segmentation and budget policy versions, the source digest, and the part count. One per translation.

- **Lifecycle:** Immutable.
- **Keys:** PK `id` · FK `experiment_id` → `experiments(id)`, ON DELETE RESTRICT · UK `(experiment_id)`
- **Integrity:** 3 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L1548)

### `experiment_segments`

One ordered part of the source with its length and digest. Rejoining all parts reproduces the source exactly.

- **Lifecycle:** Immutable.
- **Keys:** PK `id` · FK `document_execution_plan_id` → `document_execution_plans(id)`, ON DELETE RESTRICT · UK `(document_execution_plan_id, id)` · UK `(document_execution_plan_id, position)`
- **Integrity:** 3 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L1665)

### `translation_segment_runs`

One candidate's translation of one part.

- **Lifecycle:** Durable; sealed once completed. Only failed parts are retried.
- **Keys:** PK `id` · FK `experiment_segment_id` → `experiment_segments(id)`, ON DELETE RESTRICT · FK `translation_run_id` → `translation_runs(id)`, ON DELETE RESTRICT · UK `(translation_run_id, id)` · UK `(translation_run_id, experiment_segment_id)`
- **Integrity:** 14 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L3227)

### `review_segment_runs`

One reviewer's evaluations of one part, aggregated into the run's evaluations.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `review_run_id` → `review_runs(id)`, ON DELETE RESTRICT · FK `experiment_segment_id` → `experiment_segments(id)`, ON DELETE RESTRICT · UK `(review_run_id, id)` · UK `(review_run_id, experiment_segment_id)`
- **Integrity:** 14 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L2844)

### `judge_segment_runs`

One judge's judgment of one part, aggregated with source-length weights.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `experiment_segment_id` → `experiment_segments(id)`, ON DELETE RESTRICT · FK `judge_run_id` → `judge_runs(id)`, ON DELETE RESTRICT · UK `(judge_run_id, id)` · UK `(judge_run_id, experiment_segment_id)`
- **Integrity:** 14 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L2356)

### `finalization_segment_runs`

One AI suggestion for one part, reassembled into the full suggestion.

- **Lifecycle:** Durable; sealed once completed.
- **Keys:** PK `id` · FK `finalization_run_id` → `finalization_runs(id)`, ON DELETE RESTRICT · FK `experiment_segment_id` → `experiment_segments(id)`, ON DELETE RESTRICT · UK `(finalization_run_id, id)` · UK `(finalization_run_id, experiment_segment_id)`
- **Integrity:** 17 CHECK constraints, 3 triggers · [schema](../../db/structure.sql#L2007)

### `final_translation_version_segments`

A final version's text split along the source parts, used for segmented AI suggestions.

- **Lifecycle:** Immutable. A manual edit marks the version's alignment invalid instead of rewriting segments.
- **Keys:** PK `id` · FK `experiment_segment_id` → `experiment_segments(id)`, ON DELETE RESTRICT · FK `final_translation_version_id` → `final_translation_versions(id)`, ON DELETE RESTRICT · UK `(final_translation_version_id, experiment_segment_id)`
- **Integrity:** 1 CHECK constraint, 2 triggers · [schema](../../db/structure.sql#L1776)

## Reusable guidance

### `glossaries`

User-owned glossary handle: active flag and pointer to the current revision.

- **Lifecycle:** Archived (inactive) instead of deleted.
- **Keys:** PK `id` · FK `id, current_revision_id` → `glossary_revisions(glossary_id, id)` · FK `user_id` → `users(id)`, ON DELETE RESTRICT
- **Integrity:** 0 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L2084)

### `glossary_revisions`

A versioned glossary snapshot: name, language pair, and configuration digest.

- **Lifecycle:** Append-only and immutable.
- **Keys:** PK `id` · FK `glossary_id` → `glossaries(id)`, ON DELETE RESTRICT · UK `(glossary_id, id)` · UK `(glossary_id, version)`
- **Integrity:** 6 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L2156)

### `glossary_entries`

Ordered term pairs (source term, preferred target term, note) in one revision.

- **Lifecycle:** Sealed with the revision's entry set.
- **Keys:** PK `id` · FK `glossary_revision_id` → `glossary_revisions(id)`, ON DELETE RESTRICT · UK `(glossary_revision_id, position)` · UK `(glossary_revision_id, source_term)`
- **Integrity:** 4 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L2117)

### `methodology_profiles`

User-owned methodology (style guide) handle.

- **Lifecycle:** Archived instead of deleted.
- **Keys:** PK `id` · FK `id, current_revision_id` → `methodology_profile_revisions(methodology_profile_id, id)` · FK `user_id` → `users(id)`, ON DELETE RESTRICT
- **Integrity:** 0 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L2514)

### `methodology_profile_revisions`

A versioned methodology snapshot: guidance text, language pair, and digest.

- **Lifecycle:** Append-only and immutable.
- **Keys:** PK `id` · FK `methodology_profile_id` → `methodology_profiles(id)`, ON DELETE RESTRICT · UK `(methodology_profile_id, id)` · UK `(methodology_profile_id, version)`
- **Integrity:** 8 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L2468)

### `translation_references`

User-owned reference handle.

- **Lifecycle:** Archived instead of deleted.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE RESTRICT · FK `id, current_revision_id` → `translation_reference_revisions(translation_reference_id, id)` · UK `(user_id, id)`
- **Integrity:** 0 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L3127)

### `translation_reference_revisions`

A versioned approved example: source text, approved translation, language pair, and digest.

- **Lifecycle:** Append-only and immutable.
- **Keys:** PK `id` · FK `translation_reference_id` → `translation_references(id)`, ON DELETE RESTRICT · UK `(translation_reference_id, id)` · UK `(translation_reference_id, version)`
- **Integrity:** 8 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L3081)

### `experiment_reference_revisions`

Ordered join (positions 1–5) between a translation and the exact reference revisions it used.

- **Lifecycle:** Created before any candidate exists; immutable afterwards.
- **Keys:** PK `id` · FK `translation_reference_revision_id` → `translation_reference_revisions(id)`, ON DELETE RESTRICT · FK `experiment_id` → `experiments(id)`, ON DELETE RESTRICT · UK `(experiment_id, position)` · UK `(experiment_id, translation_reference_revision_id)`
- **Integrity:** 1 CHECK constraint, 2 triggers · [schema](../../db/structure.sql#L1631)

## Automatic workflow

### `workflow_profiles`

UI: **Workflow setup** handle.

- **Lifecycle:** Deactivated instead of deleted.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE RESTRICT · FK `id, current_revision_id` → `workflow_profile_revisions(workflow_profile_id, id)`
- **Integrity:** 0 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L3581)

### `workflow_profile_revisions`

A versioned setup: completion mode and configuration digest.

- **Lifecycle:** Append-only and immutable.
- **Keys:** PK `id` · FK `workflow_profile_id` → `workflow_profiles(id)`, ON DELETE RESTRICT · UK `(workflow_profile_id, id)` · UK `(workflow_profile_id, version)`
- **Integrity:** 5 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L3540)

### `workflow_profile_model_selections`

Models per role and order in a revision, with snapshots of display name, provider, gateway, and identifier.

- **Lifecycle:** Immutable.
- **Keys:** PK `id` · FK `llm_model_id` → `llm_models(id)`, ON DELETE RESTRICT · FK `workflow_profile_revision_id` → `workflow_profile_revisions(id)`, ON DELETE RESTRICT · UK `(workflow_profile_revision_id, role, llm_model_id)` · UK `(workflow_profile_revision_id, role, position)`
- **Integrity:** 6 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L3496)

### `pipeline_runs`

UI: **Automatic workflow** for one translation: status, current or blocked stage, the approved request plan (`provider_work_plan`), role counts, and the recovery cursor `last_reconciled_at`.

- **Lifecycle:** Durable. Ends in ready_for_editor or stopped; never finalizes.
- **Keys:** PK `id` · FK `finalization_round_id` → `finalization_rounds(id)`, ON DELETE RESTRICT · FK `experiment_id` → `experiments(id)`, ON DELETE RESTRICT · FK `workflow_profile_revision_id` → `workflow_profile_revisions(id)`, ON DELETE RESTRICT · UK `(experiment_id)` · UK `(finalization_round_id)` WHERE (finalization_round_id IS NOT NULL)
- **Integrity:** 14 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L2591)

### `pipeline_events`

Ordered, idempotent timeline events (`event_key` unique per run).

- **Lifecycle:** Append-only and immutable.
- **Keys:** PK `id` · FK `pipeline_run_id` → `pipeline_runs(id)`, ON DELETE RESTRICT · UK `(pipeline_run_id, event_key)` · UK `(pipeline_run_id, sequence_number)`
- **Integrity:** 7 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L2547)

## AI attempt ledger

### `ai_provider_attempts`

Execution-attempt ledger for all eight run types: snapshots of the routed model, timing, sanitized error code, and reported usage and cost. Written when a job claims a run, before the request is sent.

- **Lifecycle:** Append-only; identity is immutable and completed or failed attempts are sealed. Runs cannot be deleted while attempts exist.
- **Keys:** PK `id` · UK `(provider_run_type, provider_run_id, attempt_number)`
- **Integrity:** 18 CHECK constraints, 2 triggers · [schema](../../db/structure.sql#L1438)

## Request coordination

### `source_imports`

A staged upload: signed request key, extraction status and text, failure code, expiry, and the document it was consumed into.

- **Lifecycle:** Unconsumed rows expire after 24 hours and are cleaned hourly; consumed rows stay as provenance.
- **Keys:** PK `id` · FK `resulting_document_id` → `documents(id)`, ON DELETE RESTRICT · FK `user_id` → `users(id)`, ON DELETE RESTRICT · UK `(resulting_document_id)` WHERE (resulting_document_id IS NOT NULL) · UK `(user_id, request_key)` WHERE (request_key IS NOT NULL)
- **Integrity:** 8 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L2988)

### `source_import_retirements`

Tombstones for cancelled upload keys, so a late retry cannot resurrect a cancelled upload.

- **Lifecycle:** Expire at their signed deadline; cleaned hourly.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE RESTRICT · UK `(user_id, request_key)`
- **Integrity:** 1 CHECK constraint, 0 triggers · [schema](../../db/structure.sql#L2955)

### `translation_reference_creations`

Replay ledger for creating a reference: signed creation key, payload digest, outcome, and an encrypted failure outcome for safe retries.

- **Lifecycle:** Retained until the later of the signed deadline and 24 hours after admission; cleaned hourly.
- **Keys:** PK `id` · FK `user_id` → `users(id)` · FK `user_id, translation_reference_id` → `translation_references(user_id, id)` · UK `(translation_reference_id)` · UK `(user_id, creation_key)`
- **Integrity:** 3 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L3041)

### `translation_workspace_submissions`

Single-use launch identities (stored as digests) and the translation each created.

- **Lifecycle:** Unused identities expire after 24 hours and are cleaned; consumed ones stay as launch history.
- **Keys:** PK `id` · FK `experiment_id` → `experiments(id)`, ON DELETE RESTRICT · FK `user_id` → `users(id)`, ON DELETE RESTRICT · UK `(experiment_id)` WHERE (experiment_id IS NOT NULL) · UK `(token_digest)`
- **Integrity:** 4 CHECK constraints, 1 trigger · [schema](../../db/structure.sql#L3378)

### `translation_workspace_drafts`

One encrypted autosaved form per user and context (`new` or `project:<id>`), with `lock_version` and the editor that wrote last.

- **Lifecycle:** Expire after 7 days; removed by hourly cleanup, by Discard, after a successful launch, or when an expired or unreadable draft is replaced during autosave.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE CASCADE · UK `(public_id)` · UK `(user_id, context_key)`
- **Integrity:** 5 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L3335)

### `translation_workspace_draft_editors`

Per-page editor watermark: the highest accepted sequence and state (active, rejected, retired) under a signed 24-hour lease.

- **Lifecycle:** Outlive drafts until their deadline; cleaned hourly with `SKIP LOCKED`.
- **Keys:** PK `id` · FK `user_id` → `users(id)`, ON DELETE CASCADE · UK `(user_id, context_key, editor_id)`
- **Integrity:** 3 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L3298)

## Files

### `active_storage_blobs`

Metadata for a stored file; the bytes live on the private storage volume.

- **Lifecycle:** Unattached blobs older than seven days are purged daily with a bounded retry.
- **Keys:** PK `id` · UK `(key)`
- **Integrity:** 0 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L1370)

### `active_storage_attachments`

Polymorphic link from a `Document` or `SourceImport` to its blob.

- **Lifecycle:** Follows its record.
- **Keys:** PK `id` · FK `blob_id` → `active_storage_blobs(id)` · UK `(record_type, record_id, name, blob_id)`
- **Integrity:** 0 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L1336)

### `active_storage_variant_records`

Active Storage variant metadata; the application stores text documents and does not generate variants.

- **Lifecycle:** Follows its blob.
- **Keys:** PK `id` · FK `blob_id` → `active_storage_blobs(id)` · UK `(blob_id, variation_digest)`
- **Integrity:** 0 CHECK constraints, 0 triggers · [schema](../../db/structure.sql#L1408)

## Rails metadata

`schema_migrations` records applied migrations and `ar_internal_metadata` records the environment; both are managed by Rails.

## Operational databases (production only)

| Database | Schema file | Tables |
| --- | --- | --- |
| Solid Queue | `db/queue_schema.rb` | 13 `solid_queue_*` tables (jobs, ready/scheduled/claimed/blocked/failed executions, processes, recurring tasks, semaphores, pauses, batches) |
| Solid Cache | `db/cache_schema.rb` | `solid_cache_entries` |
| Solid Cable | `db/cable_schema.rb` | `solid_cable_messages` |

These hold rebuildable operational state. They are not authoritative for paid-work approval or translation history; disaster recovery rebuilds the queue empty.
