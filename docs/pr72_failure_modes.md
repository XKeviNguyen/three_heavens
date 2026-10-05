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

| Mechanism | Normal path | Attacker input | Max durable cardinality | Replay horizon | Failure state | Lost response | Cleanup policy | Poison behavior | Concurrency | Migration |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Upload admission/source import | One extraction/blob per keyed action | Suffix; bounded file | 10 charged actions/5min/account; one budget row, <=10 receipts | Signed 24h; storage availability 24h | Pending/failed retained; prework Busy removes unperformed action and refunds exact receipt | Replays outcome without extraction/charge | Hourly fixed-cutoff forward sweep, <=100/job | Skip action/row locks; advance past prefix | Atomic budget UPSERT, action advisory and row locks | Canonical varchar unchanged; CHECK online; partial index concurrent |
| Import retirement | Cancellation blocks resurrection | Owned import/key | <=1 tombstone/admitted action | Signed deadline; legacy 24h | No retained content | Retry 404 clears only matching UI provenance; expired credential cannot recreate | Hourly <=100 SKIP LOCKED | Locked rows do not occupy limit | Action lock; independently expired admission | Atomic new-table metadata |
| Editor watermark | Orders page save/discard | Complete owner/context credential, integer sequence | <=1/credential/context; <=256/account | Signed nonrenewable 24h | Single active/rejected/retired state; losers remain rejected | Rejected retries conflict; successful retirement retries succeed only with no newer draft | Hourly <=100 SKIP LOCKED | Locked rows skipped | First-admission owner lock; editor then draft | Atomic new-table metadata; resumable backfill outside parent locks |
| Encrypted draft | One encrypted row/context | Allowlisted bounded payload | <=1/account/context; owned project contexts | Rolling content 7d; editor 24h | Stale conflict preserves winner; unreadable content explicitly replaceable | Same-sequence retry; DOM counter/dirty bit survive reconnect without browser content storage | Hourly <=100 expiry batch | SKIP LOCKED | Editor then draft; owner/context unique index | Brief CHECK swap then online validation |
| Reference creation | One immutable outcome | Complete key; bounded text/file | <=1/key/account; <=256/account; files share upload budget | Signed 24h; ledger >=24h from admission | Pending/failed/completed retained; recovery ciphertext cleared at24h | Returns original outcome; pending interrupted never creates duplicate | Hourly <=100/phase forward sweep | Skip action locks; recovery SKIP LOCKED | Action/owner/row locks; owner FK | Canonical concurrent index repaired before atomic new table |
| Workspace launch | One launch/token | Complete owner token; validated form | <=256 available/account; consumed intentional history | Signed24h; consumed replay canonical | Invalid form retains correction action | All-status identity rechecked under admission lock at capacity; consumed workflow reused | Hourly <=100 available rows, bounded successors | SKIP LOCKED | Owner admission/token unique/submission row lock | Existing schema unchanged |
| Blob recovery/purge | Delete disk objects while retaining retry identity until success | Bounded uploads; no public retry setter | One field/existing blob; no auxiliary rows | Default age7d; retry1h | Filesystem failure rolls back deletion; missing service retains row | Claim deadline survives crash; idempotent disk delete | Daily trigger, <=100 claims/job, bounded successors; explicit cutoff respected | Failure/service outage isolates item, later healthy peers continue; no immediate retry storm | Blob claim/purge row lock; attachment FK lock | Nullable no-default column; concurrent expression index |
| Reference revisions/history | Explicit immutable revision | Owner version/content | Intentional canonical business history | Immutable version | Stale version never becomes current | Optimistic comparison remains valid after later revisions | Canonical history retained | No cleanup queue | Ownership/optimistic version/immutable constraints | No new DDL |

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
| Create three coordination tables with final keys, NOT NULL deadlines/defaults and indexes | New empty ephemeral tables | New-table locks and brief parent FK metadata locks; empty index/check scans; no existing heap rewrite | 1s lock timeout restored on exit; atomic metadata; resumable phases; down removes new table before new traffic |
| Canonical reference owner unique index | Potentially large reference history | Concurrent build scans history with SHARE UPDATE EXCLUSIVE; allows normal reads/writes | Outside metadata transaction, before ledger creation; invalid build repaired on retry; reverse concurrent drop |
| Composite reference owner FK | New empty ledger references canonical history | Brief SHARE ROW EXCLUSIVE metadata locks; NOT VALID followed by empty-table validation inside atomic metadata transaction | 1s acquisition timeout; ownership remains authoritative |
| Source/draft identity CHECK replacement | Canonical imports; seven-day draft content | Brief ACCESS EXCLUSIVE swap, NOT VALID; separate SHARE UPDATE EXCLUSIVE validation scan; no heap/type rewrite | Each swap commits before validation; 1s lock timeout; no accumulated long exclusive locks |
| Blob nullable retry metadata | Potentially large blob history | Brief ACCESS EXCLUSIVE ADD COLUMN, no default/backfill/table scan or rewrite | 1s lock timeout; guarded reverse metadata removal |
| Blob deadline and source expiry/id indexes | Potentially large history | Concurrent build/drop; no write-blocking regular build | Old serving index retained until replacement valid; interrupted INVALID replacement is repaired on rerun |
| Editor existing-draft backfill | Existing ephemeral drafts | ACCESS SHARE on drafts; inserts into new ledger, no canonical update | Outside parent FK metadata transaction; full grace from insertion; ON CONFLICT idempotent; refresh for unknown legacy identities |

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

## Additional adversarial findings

Independent reviewers reproduced consumed-launch retry refusal when a duplicate
claim loses its initial lookup race and capacity fills; successful discard retry
returning 409; cancellation retry404 leaving stale browser provenance; a removed
legacy storage service aborting all healthy batch peers; hidden cancellation feedback in the inactive upload tab, and interrupted concurrent
index creation leaving a ledger that prevented migration retry. These are fixed at
the owner lookup, terminal editor state, guarded UI removal, service lookup, and
atomic/resumable migration boundaries. Cancellation feedback now remains visible
in either source tab. A real Chrome reconnect test
also reproduced acknowledged-but-unpersisted text when the same credential's
counter reset. The page now retains its counter and dirty bit through reconnects.
The complete credential contains no source text or secrets.

Explicit cleanup cutoffs still admit younger abandoned blobs, while retry deadlines
always prevent immediate repeated failures. Unexpected storage programming exceptions
remain visible; only missing service configuration and filesystem failures are
classified as recoverable purge failures.

For a simple throughput model, let arrivals be lambda eligible rows/minute and
J completed cleanup jobs/minute. Healthy service capacity is at most 100J rows/minute;
sustained drainage requires 100J > lambda, plus capacity for retry attempts.
For example, 100 accounts at the upload bound can admit 200 actions/minute. Their
cleanup needs more than two full jobs/minute when those actions become eligible;
a daily 100-row invocation alone cannot sustain that rate. Bounded successors
provide drainage, contingent on worker throughput. A finite snapshot N costs
floor(N/100)+1 jobs, even with a completely locked prefix. Scheduler/worker outages
and permanently failed disk objects can grow upload/blob backlog; the three resident
ledger caps remain hard bounds during those outages. No production throughput SLA
is inferred from the disposable concurrency tests.
