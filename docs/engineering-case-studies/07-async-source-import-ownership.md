# Case 07 — An older import response could overwrite a newer decision

**Evidence:** [PR #77 — Fix source ownership across asynchronous workspace imports](https://github.com/XKeviNguyen/three_heavens/pull/77) (merged 2026-10-08).

**Classification:** Reproduced flow/ownership defect (FLOW-IMPORT-001), not a documented production-user data-loss incident.

## Symptom and risk

A source upload/import could be in flight while the user changed source mode or text. The delayed response from the earlier import could arrive later, install the now-outdated content, and autosave it, overwriting the newer source decision.

## Root cause

The response handler did not sufficiently prove that the asynchronous work still belonged to the *current* source generation. Transport delivery order was effectively allowed to decide which source content won. Clicking a tab that was already selected also risked unnecessarily invalidating legitimate ownership state.

## Correction

- Verify **both** the upload replay/request key and the generation that initiated the request, including after response body parsing.
- Treat genuine edits, mode changes, replacement, removal, and disconnection as superseding the old generation.
- Leave an already-selected tab click as a no-op for ownership/replay state.
- Distinguish explicit new actions (including uploading the same file again after genuine supersession) from ambiguous retries of the existing action, which retain their original identity.
- Preserve the existing `finally` settlement path; do not let superseded responses regain authority.

## Verification

PR #77 reports that a regression fails with the original controller under held-response scenarios, and the corrected 15-test/156-assertion ownership matrix passes. It also reports 1,187 Rails tests, 191 system tests at both 4 and 8 workers, CI success, and an independent read-only review on the exact PR head.

## Lesson

**Completion order does not define authority.** Async responses need operation identity and generation/ownership checks before mutating current state. Retries should be idempotent, but an intentional new action must receive a new identity.

**Interview angle:** Explain the difference between deduplicating transport retries and accepting a response that is still semantically current.
