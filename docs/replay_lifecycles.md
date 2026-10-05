# Replay coordination lifecycles

A page action has a nonrenewable 24-hour admission lease, matching the existing
workspace submission token lifetime and staged import availability window.
`ReplayIdentity` signs that deadline without writing a database row. Browsers
append a random 128-bit suffix per upload action or editor. Changing the deadline
changes the identity; changing a suffix creates a distinct action. These tokens
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

Each cleanup phase selects at most 100 rows, in timestamp/id order. A full batch schedules a bounded successor, so throughput is not limited to
100 rows/hour. Import and reference purge continue while making progress, including
partial batches that skipped live action locks, and stops on zero progress. A
delayed scheduler catches up through these successors; no job drains an entire ledger.
Parallel workers may skip work owned by another worker; subsequent scheduled
invocations converge once live locks are released. Jobs emit count-only events
through Operations::EventLogger and let failures reach normal job failure handling.
No identity, text, recovery payload, or file content is included in these events.

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

The new migration retains the old 32-character format for existing records and
adds a full 24-hour grace period at migration time. Unknown legacy keys cannot
create new actions or watermark rows. Therefore deleting their final protective
row cannot resurrect them. Widened columns store the signed protocol and retain
existing owner/key unique indexes and foreign keys.

Rollback is safe before signed identities are stored. Once signed identities
exist, rollback deliberately fails instead of truncating keys or removing
protection. Consumed import provenance may retain signed keys permanently, so
draining ephemeral rows does not always permit a downgrade. Use a forward
correction; do not erase canonical records merely to force a rollback.

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
