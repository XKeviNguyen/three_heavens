# Case 12 — Duplicate uploads, lost responses and atomic admission limits

**Evidence:** [PR #64](https://github.com/XKeviNguyen/three_heavens/pull/64), [PR #71 — V1.1 final mega stabilization](https://github.com/XKeviNguyen/three_heavens/pull/71), [PR #72](https://github.com/XKeviNguyen/three_heavens/pull/72). All three were merged.

**Classification:** Reproduced audit/breaker findings; no assertion of a real production incident or duplicate provider bill.

## Problem and impact

An upload could commit its database record but the response could disappear. Retrying the *same* logical upload previously produced two imports and an error when the client expected one. A concurrent duplicate could incorrectly report an upload as ready **before** its storage object existed. Admission quotas and retries added a second correctness constraint: racing requests must not overspend a per-account upload budget.

## Root cause

An HTTP request ID alone cannot guarantee durable completion. The import metadata transaction, binary object write, budget charge and response acknowledgement complete at different times. Without a shared replay key and atomic admission, a retry may start duplicate work; without waiting for storage completion, it may report false success. PR #71 also identified that upload budgets could charge text-only or pre-work Busy requests incorrectly; subsequent correction unified budget scope and refunds.

## Solution

- Generate one random request key per user-initiated upload action, enforced by a unique index on `(user_id, request_key)`. A new intentional upload receives a new key, even for identical bytes.
- Reuse the original key after a lost response or retryable server error; replay the existing outcome instead of creating a second blob/import.
- Hold the per-user/per-key PostgreSQL advisory lock across the complete delivery, including storage write; concurrent duplicates wait and observe the final same result or failure.
- Enforce a shared account upload quota through atomic database admission and consistent budget receipts. Text-only edits do not spend file-upload quota, and pre-work Busy responses are refunded when no file work occurred.
- Preserve cleanup/recovery metadata and bounded retry behavior rather than treating each HTTP delivery as independent work.

## Verification

PR #64 documents a lost-response retry: the old implementation produced two imports / `SoleRecordExceeded`; the corrected implementation yielded **one import and one blob**. It also reproduced the false-ready outcome by holding open the object write after DB commit, then testing concurrent replay. PRs #71 and #72 document quota/interleaving regression coverage, including atomic budget admission and bounded replay/cleanup.

## Lesson

**Deduplicate at the domain boundary and include downstream durability in the result.** Exactly one database row is not enough if the object is missing, and a rate limiter is not safe under concurrency if its check and increment are separate. Preserve the distinction between *retry of the same action* and *new intentional upload*.

**Interview angle:** Explain why the server's replay identity, PostgreSQL lock and atomic quota each solve different problems.
