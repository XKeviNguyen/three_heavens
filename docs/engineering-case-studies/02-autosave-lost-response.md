# Case 02 — Autosave lost an edit after a lost response

**Evidence:** [PR #64](https://github.com/XKeviNguyen/three_heavens/pull/64) (merged 2026-09-29).

**Classification:** P1 data-loss scenario identified in release/flow audit; no customer production incident claimed.

## Symptom and risk

Autosave A could commit successfully while its HTTP response was lost. The browser retained an old draft version. When the user continued editing (B), the next save could be rejected as a conflict against the user's own prior save. Refreshing the page recovered A but not B. Other edge cases included ambiguous pending saves, discard retries, and Back/Forward restoration of stale Turbo state.

## Root cause

The client treated receipt of the server response as the only indication that its version had advanced. That conflated **unknown delivery outcome** with **failed commit** and made the next local edit look like a competing writer. Uncoordinated retry/response timing and browser snapshot caching increased the problem.

## Correction

- Each page editor receives a random 128-bit identity, kept in memory, and monotonically numbered saves.
- Retries of the same unacknowledged snapshot reuse its sequence; duplicate or old sequences are acknowledged without rewriting.
- The server evaluates these rules under a row lock. A later sequence from the same editor can follow its own earlier committed save; genuinely different editors still require current version/identity and receive HTTP 409 on conflict.
- Client saves are serialized, transient failures have bounded retries, discard is terminal, and the workspace is excluded from Turbo's snapshot cache.

## Verification

PR #64 reports dedicated regression coverage for lost responses, pending dirty state, cross-tab conflicts, duplicate acknowledgements, discard behavior, reconnect, and Turbo navigation. The compatibility path for clients without editor identity retains optimistic concurrency controls.

## Lesson

**A network timeout does not reveal whether a write committed.** Design writes to be safe on replay, track operation identity, and separate a user's own ordered edits from concurrent edits by another actor. Test lost acknowledgements explicitly rather than testing only successful HTTP round trips.

**Interview angle:** Describe how idempotency and optimistic concurrency complement each other, rather than replacing one another.
