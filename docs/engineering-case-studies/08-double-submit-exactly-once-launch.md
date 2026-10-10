# Case 08 — Double-clicking Start must not launch paid AI work twice

**Evidence:** [PR #21 — Harden automatic pipeline launch and recovery](https://github.com/XKeviNguyen/three_heavens/pull/21) (merged 2026-08-29); [PR #64 — Fix V1.1 recovery, autosave, and idempotency blockers](https://github.com/XKeviNguyen/three_heavens/pull/64) (merged 2026-09-29).

**Classification:** Confirmed replay/double-submit correctness boundaries and regression scenarios, not a claimed real-world duplicate charge.

## Problem and impact

A user might double-click **Start translation**, submit the same request twice, retry after a timeout, or return to an already-submitted page. If each delivery creates a fresh `Experiment` / `PipelineRun`, the system could schedule paid model work twice and produce inconsistent results.

## Root cause / failure boundary

Browser button disabling is not a durable exactly-once guarantee: network retries and concurrent HTTP deliveries can bypass it. A request must carry an action identity, and the server must serialize the *business decision to launch* rather than infer uniqueness from button state. PR #64 also identified an avoidable submission-row write on each New Translation GET; creating tokens on display was unnecessary.

## Solution

- Mint owner-scoped opaque one-time submission identities; retain SHA-256 digests rather than raw tokens in the database.
- Validate ownership across the initiating user, profile, and target experiment, without an administrative bypass.
- Serialize competing deliveries against the same submission row and replay the original `Experiment` / `PipelineRun` once consumed.
- When a delivery repeats, schedule **zero additional provider work**.
- Use a read-only token-generation path on GET; only create durable submission state when a launch needs it.
- Preserve explicit retry semantics for setup or enqueue partial failures.

## Verification

PR #21 reports corrective unit/system regressions around ownership, replay, and duplicate launch. PR #64 reports a browser **double Start** exercise creating exactly one launch with zero provider attempts, replay assertions, and GET-path no-write checks. These are test results; no real paid-provider charge was triggered to prove the invariant.

## Lesson

**Exactly-once is a server-side business invariant, not a UI affordance.** Bind each logical action to a stable identity, serialize competitors at the authoritative data boundary, and make repeated delivery return the same outcome. Distinguish retries of one action from a user's intentional new action.

**Interview angle:** Explain why `disabled=true` on a button does not prevent duplicate paid jobs.
