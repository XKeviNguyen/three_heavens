# PR #72 failure-mode audit

The reviewed baseline is `7d31de73d068298fdd1a0391c574d8295b106953`;
the integration base is `8e09b9c1862daa9ff6c689cafd04f5ad021691fc`.
This audit covers the complete PR, including its previous corrective changes.

## Confirmed reproductions before correction

| Finding | Deterministic baseline evidence | Correction |
| --- | --- | --- |
| P1 editor amplification | One rendered page lease, 1,000 changed suffixes, no-draft discard: 1,000 editor rows | Sign the complete nonce, owner and context; reject suffix/domain/owner/context mutation before insertion. Require editor admission on the HTTP API. |
| P2 losing-editor resurrection | B saves; A sequence 1 conflicts; B discards; exact A sequence 1 retry creates a draft | Retain the sequence and a terminal rejected marker. Neither exact nor higher deliveries from that editor become valid after competing state disappears. Save, discard and launch removal preserve this ordering. |
| P2 blob starvation | Oldest 100 delete calls persistently raise IOError; three 100-row invocations never reach the healthy five-row tail | Claim a bounded batch with a retry deadline before storage work; failed/crashed attempts remain discoverable but leave the immediate candidate set. |
| P2 migration lock | 10,000 synthetic consumed-history rows, independent DDL session at narrowing ALTER, pipe barrier, application SELECT fails at its 100ms lock timeout | Keep canonical unconstrained varchar; separate metadata swaps from online validation, use concurrent indexes and a one-second lock timeout. |

Every reproduction used synthetic data. Storage failures were injected at the
filesystem boundary; row selection, transactions and rollback were real PostgreSQL.

## Admission and backlog bounds

A complete editor credential signs its nonce, user and exact context. One page
credential can create at most one editor row. New page loads issue independent
credentials without creating rows. There is no client nonce minting for editors.
Reference creation likewise requires a complete signed nonce, rather than an
upload lease with freely chosen suffixes. Neither credential authorizes access.
Ownership checks remain separate.

An account may hold at most **256 resident rows per ledger** for editors,
reference creation, and available workspace submissions. This is an explicit
operational admission capacity, not a retention estimate: it allows hundreds
of separate page actions while putting a hard ceiling on a malicious account's
coordination footprint. The owner advisory transaction lock serializes first
admissions; an indexed count capped at 256 runs before insertion or extraction.
Existing identities replay at capacity. No extra counter/reservation table is
created. Expired rows still count until purged, so cleanup delay cannot turn
these three bounds into unlimited growth. Admission refusal retains browser
text and requires waiting/reloading. Consumed workspace submissions are canonical
launch history and are excluded from the available-row cap.

Uploads deliberately retain client action suffixes: the authoritative PostgreSQL
UploadBudget admits at most 10 new uploads per fixed five-minute window, across
source imports and reference files. A 24-hour interval intersects at most 289
such windows, or 2,890 charged admissions per account. Replay is checked before
charging; Busy refunds are receipt-specific and accompany removal of the
unperformed action. A cancelled/failed/completed upload does not refund its
admission. Pending process-loss state prevents repeating extraction/charge.
Extraction byte/process/deadline limits remain unchanged. Canonical consumed
imports grow with intentional business history, not with replay deliveries.

The 24-hour signed deadline does not renew with activity. Editor/creation
identities, including negative outcomes, are purged after their documented
retention; encrypted draft content has its separate seven-day retention.
Migration legacy keys can only replay existing records during grace. Unknown
legacy keys and expired signed credentials cannot create missing state.

## Failure-mode table

| Mechanism | Normal path | Attacker input | Durable cardinality | Replay horizon | Failure state / lost response | Cleanup / poison behavior | Concurrency | Migration implication |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Upload admission / source import | One extraction/blob per keyed action | Upload suffix and bounded file | <=10 charged new actions/5min/account; one budget row/account, <=10 receipts | Signed 24h; staged availability 24h after storage | Pending survives process loss; replay returns outcome; pre-work Busy is retryable with no durable effect | Hourly bounded forward sweep; live action/row locks do not monopolize the candidate window | Atomic budget UPSERT, per-action advisory lock, row locks | Canonical key remains varchar; format validation online; partial expiry/id index concurrent |
| Import retirement | Cancelled action stays unavailable | Existing owned import/key | At most one tombstone per admitted action, within upload bound | Signed deadline; legacy 24h grace | Lost cancel/replay never resurrects import, even after purge | Hourly, <=100, SKIP LOCKED; bulk delete | Action lock plus independently expired admission | New empty table, final key/deadline/index definitions directly |
| Editor watermark | Sequence orders one page's save/discard | Complete credential and bounded integer sequence | One row/credential/context; <=256/account | Nonrenewable signed 24h | Ordering loser stays rejected through winner discard/launch/expiry; exact and higher retries conflict | Hourly, <=100, SKIP LOCKED; no per-autosave lifetime churn | Owner admission lock for first insertion, editor then draft locks | New table plus existing-draft backfill; canonical draft key not altered |
| Encrypted draft | One encrypted content row per owned context | Allowlisted, bounded payload | One/user/context; contexts follow canonical owned projects | Editor lease separate from rolling 7-day content | Unknown save outcome retries same sequence; stale conflict requires fresh page; terminal discard rejects old-page saves | Hourly <=100 expiry batch; SKIP LOCKED advances past row locks | Editor lock then draft lock, owner/context unique index | Existing key CHECK swapped briefly then validated online |
| Reference creation | One immutable creation outcome | Complete key; bounded text/file | One/key/account; <=256/account; file admissions share UploadBudget | Signed 24h; ledger at least 24h after admission | All statuses retain outcome; failed encrypted recovery cleared at 24h; pending interruption never duplicates reference; unperformed Busy may retry | Hourly <=100 phases; forward keyset sweep passes advisory-locked prefix; recovery phase SKIP LOCKED | Action lock, owner admission lock, row locks, owner FK | New table/indexes; canonical owner index concurrent; FK NOT VALID then validate |
| Workspace launch | One launch per complete owner-bound token | Signed token and validated workspace | <=256 available/account; consumed rows intentional canonical history | Signed 24h; consumed replay canonical | Invalid form retains available action for correction; response loss replays consumed workflow, never launches twice | Hourly <=100 available-row bulk delete, SKIP LOCKED and bounded successors | Owner admission lock, token unique index, submission row lock, domain constraints | Existing table/schema unchanged |
| Blob recovery/purge | Delete storage before losing retry identity | Owned bounded uploads; no public cleanup marker setter | One retry field on the existing blob; no auxiliary retry rows | Unattached age 7d; failed attempts eligible again after 1h | I/O failure rolls back row deletion; claim deadline survives crash; attachment recheck prevents deletion | Daily trigger plus bounded successors; <=100 claims; failing prefix deferred, no immediate retry storm | Claim FOR UPDATE OF blobs SKIP LOCKED; purge row lock plus attachment FK locking | Nullable column without backfill/rewrite; expression deadline/id index concurrent |
| Reference revisions / canonical history | Explicit revision with optimistic version | Owner-scoped revision/version/content | Canonical business data, intentional retention | Version precondition remains tied to immutable revision history | Exact stale version cannot become current after later immutable revisions | No deletion of canonical history to satisfy this audit | Ownership, optimistic version, immutable history constraints | No additional DDL in this corrective pass |

## Cleanup fairness and throughput

Source import and reference identity jobs carry an expiry/id cursor and fixed
cutoff through each sweep. Even a full batch of live advisory locks advances
the cursor. Each successor examines at most 100 candidates and never restarts
that sweep. A finite snapshot of N candidates takes at most floor(N/100)+1
invocations; an hourly fresh sweep retries skipped work. No cursor table is added.
Row-lock cleanup uses SKIP LOCKED within the bounded SELECT, so locked rows do
not occupy the result limit.

Blob cleanup commits `cleanup_retry_at = now + 1 hour` before attempting each
claimed batch. The indexed eligibility expression excludes those rows until
retry, including after a process crash. A full claimed batch schedules one
successor; a partial/empty batch stops. Thus 100 persistent failures receive
100 attempts, then leave capacity for healthy newer items; they cannot repeatedly
schedule themselves immediately. A later daily trigger retries them after the
deadline. Attached blobs are never eligible, and purge rechecks attachment state
under the blob lock. Disk deletion remains idempotent after response/process loss.
Retry metadata dies with its blob and cannot amplify durable cardinality.

The model assumes recurring jobs/workers are operational. Scheduler downtime
can delay source/import/blob cleanup; an hourly/daily recovery trigger drains
finite snapshots through successors. Permanently held action locks preserve
live work rather than deleting it. Other healthy items still receive service.
There is no guarantee of storage deletion while the storage service fails forever.

## PostgreSQL migration safety

All four modified migration versions exist only on this unmerged PR; none exists
on develop. Correcting them removes unnecessary intermediate DDL rather than
shipping a second migration after an unsafe first one. A previously migrated
local PR database needs a disposable rebuild/rehearsal; production starts from
develop. No merged migration is rewritten.

| Operation | Data / size | Lock and scan/rewrite | Deployment and rollback |
| --- | --- | --- | --- |
| Create three coordination tables with final keys, NOT NULL deadlines/defaults and indexes | New empty ephemeral tables | New-table locks and brief parent FK metadata locks; empty index/check scans; no existing heap rewrite | 1s lock timeout; backfill existing editor/sequence with fresh grace; down removes new table before new traffic |
| Canonical reference owner unique index | Potentially large reference history | Concurrent build scans history with SHARE UPDATE EXCLUSIVE; allows normal reads/writes | Outside migration transaction; reverse concurrent drop |
| Composite reference owner FK | New empty ledger references canonical history | Brief SHARE ROW EXCLUSIVE metadata locks; NOT VALID followed by separate validation | 1s acquisition timeout; ownership remains authoritative |
| Source/draft identity CHECK replacement | Canonical imports; seven-day draft content | Brief ACCESS EXCLUSIVE swap, NOT VALID; separate SHARE UPDATE EXCLUSIVE validation scan; no heap/type rewrite | Each swap commits before validation; 1s lock timeout; no accumulated long exclusive locks |
| Blob nullable retry metadata | Potentially large blob history | Brief ACCESS EXCLUSIVE ADD COLUMN, no default/backfill/table scan or rewrite | 1s lock timeout; guarded reverse metadata removal |
| Blob deadline and source expiry/id indexes | Potentially large history | Concurrent build/drop; no write-blocking regular build | Old serving index retained until replacement valid; interrupted INVALID replacement is repaired on rerun |
| Editor existing-draft backfill | Existing ephemeral drafts | ACCESS SHARE on drafts; inserts into new ledger, no canonical update | Full grace from insertion; ON CONFLICT idempotent; refresh required for unknown legacy identities |

An unavoidable metadata swap can wait up to one second; failure aborts safely
instead of queuing indefinitely. The independent-process rehearsal holds an
application writer, proves safe timeout, then pauses real validation with a pipe:
10,000 consumed rows remain readable and writable with a 100ms application
lock timeout, no ACCESS EXCLUSIVE lock or source-import heap rewrite, and the
canonical column retains PostgreSQL typmod -1 (unconstrained varchar).

Rollback is supported before signed traffic. Once signed identities exist in
any ledger or canonical key column, the lifecycle migration refuses downgrade;
use a forward correction rather than deleting history/protection.

## Observability and intentional decisions

Existing operations events report bounded cleanup counts. Parameter filtering
covers editor, request and creation identities; events contain no keys, content,
or recovery payloads. Storage failures retain their discoverable blob row and
normal error visibility. No metrics platform, durable cursor ledger, or new
reservation table is introduced.

The 256-row cap is a deliberate admission capacity. It is not a claim about
production traffic demand; reaching it refuses new actions until cleanup frees
capacity. Canonical references/revisions, consumed imports and consumed launch
history intentionally remain permanent. Production latency, storage/provider
behavior, and deployment have not been exercised by local rehearsals.
