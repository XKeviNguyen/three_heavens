# Case 11 — Two tabs creating their first draft raced on uniqueness

**Evidence:** [PR #66 — Fix final V1.1 release-audit blockers](https://github.com/XKeviNguyen/three_heavens/pull/66) (merged 2026-09-30).

**Classification:** Actual CI/release-audit failure reproduced deterministically; not a documented live production incident.

## Problem and impact

Two tabs or browser writers attempted the **first** save of the same draft context concurrently. Rather than allowing exactly one draft with a clean winner/loser conflict, the loser could raise `ActiveRecord::RecordInvalid: Context key has already been taken`. This leaked an internal concurrency failure and complicated safe autosave retries.

## Root cause

One request read the absence of the draft and proceeded toward insertion. The other transaction committed between the loser's locked lookup and insert. An application-level uniqueness validation fired **before** PostgreSQL raised `RecordNotUnique`, but the existing recovery path handled only the latter. A database uniqueness constraint was necessary but insufficient for graceful user-facing conflict handling.

## Solution

- Handle both legitimate outcomes of that interleaving, including the Active Record uniqueness-validation path.
- Keep the authoritative database uniqueness constraint and the existing lock/order contract.
- Preserve non-uniqueness validation errors as real failures; do not swallow broad `RecordInvalid` exceptions.
- Return a correct conflict for the losing editor while preserving the winner and its saved text.

## Verification

PR #66 documents a deterministic interleaving regression that failed before the fix and a **100-iteration, two-tab race test** validating one draft, one winner, one conflict, editor/sequence integrity, and no loss of later edits.

## Lesson

**Concurrency can fail before the exception you expected.** `UNIQUE` indexes enforce data integrity, while application validation and transaction order determine which error path the user sees. Build deterministic barriers and assert the invariant, not merely a specific exception type.

**Interview angle:** Explain the difference between model validation, unique indexes and transaction serialization.
