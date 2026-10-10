# Case 10 — Replays after discard could resurrect a rejected editor

**Evidence:** [PR #72 — Fix V1.1 replay admission, recovery, and cleanup fairness](https://github.com/XKeviNguyen/three_heavens/pull/72) (merged 2026-10-07); [replay lifecycle notes at the corrective commit](https://github.com/XKeviNguyen/three_heavens/blob/9a65f7ff12d793931e6d8bfa1c62844f88975834/docs/replay_lifecycles.md).

**Classification:** Reproduced flow/concurrency bugs, not known production-user loss.

## Problem and impact

In a two-editor conflict, editor B's save won and editor A's first save was rejected. If B later discarded the draft, **retrying the exact rejected request from A could create a new draft**. Separately, an already-committed successful discard whose response was lost could return a conflict (409) on retry. A canceled import with a lost response could leave stale client provenance.

## Root cause

A naive idempotency implementation remembers only existing draft rows or successful outcomes. Removing a winning draft can erase the *negative knowledge* that editor A already lost. A retry then appears newly valid. The same problem occurs when cancellation/discard transitions are not represented as durable, terminal results for their replay horizon.

## Solution

- Represent a page/editor operation with a bounded, authenticated identity and **active / rejected / retired** terminal states.
- Keep rejected-editor outcomes through the nonrenewable 24-hour admission lease, even after the winning draft is discarded, launched, or expired.
- Reject both exact and higher-sequence retries from a previously rejected editor; do not resurrect its authority.
- Replay successful retirement only when no newer draft has superseded it.
- Preserve client sequence and dirty state across reconnects without persisting source text in browser storage.
- Make cancellation response-loss cleanup target only the matching provenance.

## Verification

PR #72 records deterministic conflict/discard/retry reproductions, regression tests at browser, service, and database boundaries, and the fully green CI suite at its reviewed head. Its failure-mode matrix documents the losing-editor resurrection scenario and the allowed replay states.

## Lesson

**Idempotency must remember both successes and denials.** A deleted business row does not imply that an older failed action has become authorized again. Model terminal state for the duration of the replay window, rather than reconstructing it from whichever row still happens to exist.

**Interview angle:** Explain why `DELETE` followed by retry is not safe unless negative outcomes remain observable.
