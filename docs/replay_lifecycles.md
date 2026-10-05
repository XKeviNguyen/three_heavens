# Replay coordination lifecycles

A page action has a nonrenewable 24-hour admission lease, matching the existing
workspace submission token lifetime and staged import availability window.
`ReplayIdentity` signs that deadline without writing a database row. Uploads
append a random 128-bit suffix under the authoritative upload budget. Editors
use a complete signed nonce bound to the user and context; references require
a complete signed nonce too. Changing a signed nonce is invalid. These tokens
are admission metadata, not authorization: each ledger still scopes ownership.

The deadline is checked inside the action lock, including after waiting. A
request with an expired identity is rejected whether or not its ledger row
still exists. Refreshing the page creates a new action/editor; it never renews
the old identity. A draft remains restorable for its existing rolling seven-day
content retention, independent of its editor lease. Expired editor requests
receive a conflict and keep the browser's local text until the user reloads.

| Record | Purpose and retention | Cleanup and index | Ordering |
| --- | --- | --- | --- |
| SourceImportRetirement | Blocks cancelled/abandoned upload resurrection until its signed deadline. Legacy keys receive 24 hours from retirement or migration. No content is retained. | SourceImportCleanupJob, hourly at minute 27; `(expires_at, id)` | Expired rows selected with `FOR UPDATE SKIP LOCKED`, bulk deleted; signed admission prevents resurrection after deletion. Retire/Create keep their shared action lock. |
| TranslationWorkspaceDraftEditor | Keeps the editor's sequence after discard, launch, or draft deletion until its signed deadline. No sliding timestamp updates. | TranslationWorkspaceDraftCleanupJob, hourly at minute 47; `(expires_at, id)` | Save/discard insert and lock the watermark, recheck admission after locking; cleanup skips locked rows. |
| TranslationReferenceCreation | Pending, completed, failed, and expired identities retain the outcome until the later of their signed deadline or 24 hours after admission. Failed encrypted recovery is cleared at 24 hours after admission, independently of identity purge. | TranslationReferenceCreationCleanupJob, hourly at minute 32; `(expires_at, id)` and partial `(created_at, id) WHERE status = 'failed'` | Cleanup skips locked rows and acquires the same action advisory lock without waiting before bulk deletion. Live actions are retained even past expiry. |

Each cleanup phase selects at most 100 rows in timestamp/id order. Source
and reference jobs carry a forward cursor and fixed cutoff through bounded
successors, including completely advisory-locked batches. A sweep never restarts
itself; the next hourly trigger retries skipped rows. Row-lock selections use
SKIP LOCKED directly. Blob cleanup claims its batch with a one-hour retry deadline
before storage work; a failing prefix cannot monopolize later healthy candidates.
Jobs emit count-only events through Operations::EventLogger and let unexpected
failures reach normal job failure handling. No identity, text, recovery payload,
or file content is included in these events.

Editors, reference outcomes and available workspace submissions each have a
256-row account admission ceiling, enforced before insertion under a PostgreSQL
owner lock. Existing deliveries replay at capacity. Rejected editor messages keep
a rejected state until admission expiry; discard and launch retire the old page.
Successful discard retries acknowledge retirement only when no newer draft exists;
rejected conflict retries remain conflicts. The page counter survives reconnects.
A refresh creates a new editor, while old exact/higher requests stay rejected.
Unsigned draft requests are refused rather than bypassing sequencing.

## Reference outcomes

- **pending:** a live creator owns the advisory lock. If that process dies, a
  replay reports interruption; cleanup can remove the abandoned identity once
  its retention deadline passes.
- **completed:** a valid retry returns the original reference, including after
  later revisions. Identity purge leaves the canonical reference and revisions.
- **failed:** valid retries return the bounded encrypted recovery outcome without
  another charge or extraction. Recovery has its own 24-hour content deadline.
- **expired:** no recovery payload remains. A still-valid legacy identity reports
  expiry until its final retention deadline; it is then deleted.

After admission expiry, every outcome rejects the old request and requires a new
submission. There is no promise of permanent idempotency for a new action key.

## Upgrade and rollback

The four PR-only unmerged migrations define the new ledgers directly with final
key formats, deadlines and cleanup indexes. The editor backfill retains existing
32-character editor/sequence records with a full 24-hour grace from insertion.
Unknown legacy keys cannot create new actions or watermark rows. Canonical import
and draft keys keep their unconstrained varchar type; CHECK constraints supply
the domain bound. Metadata CHECK swaps use short locks and separate online
validation; canonical indexes are built concurrently. A previously migrated local
PR database requires a disposable rehearsal/rebuild rather than treating the old
branch schema as a shipped migration.

Rollback is safe before signed identities are stored. Once signed identities
exist, rollback deliberately fails instead of removing protection. Consumed import
provenance may retain signed keys permanently; use a forward correction rather
than erasing canonical records to force a downgrade. See
[the failure-mode audit](pr72_failure_modes.md) for DDL locks, cardinality,
negative-state and cleanup fairness evidence.

## PR #72 durable-state audit

All newly introduced auxiliary tables are the three ledgers above. Other
materially changed durable records have intentional lifecycles:

- SourceImport pending/ready/failed rows: abandoned import cleanup at their
  existing 24-hour expiry under the creator's action lock. Consumed imports are
  canonical document provenance and remain linked to the resulting document.
- Active Storage blob/attachment rows: attached blobs follow their owner; an
  interrupted storage purge retains its blob row for bounded unattached-blob
  cleanup. No separate deletion ledger or persistent lock row is introduced.
- TranslationWorkspaceDraft: encrypted content has its existing seven-day
  expiry; its hourly deletion phase now has a fixed 100-row invocation bound.
- TranslationWorkspaceSubmission consumed records: canonical launch history
  linked to an experiment. Available records already have signed 24-hour expiry
  and bounded scheduled cleanup. This PR does not introduce that ledger.
- UploadBudget: one capped row per user, with bounded receipts and window
  rollover; this PR introduces no per-delivery budget ledger.
- PostgreSQL advisory locks: process/session state, not durable rows; disconnect
  releases them. No persistent lock-identity table is added.

Regression coverage: `test/models/replay_lifecycle_test.rb` and
`test/models/replay_lifecycle_concurrency_test.rb`, plus the existing replay,
crash, multi-tab, Back/Forward, and cancellation suites.

Missing legacy storage services retain their blob/retry deadline while healthy peers
continue. Import cancellation retries that report 404 clear only matching browser
provenance. Migration metadata is atomic; editor backfill runs after releasing parent
FK locks, and interrupted concurrent indexes are repaired before proceeding.
