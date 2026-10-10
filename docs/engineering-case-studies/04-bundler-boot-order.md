# Case 04 — Production preflight failed before Rails could boot

**Evidence:** [PR #44 — Fix production preflight Bundler boot order](https://github.com/XKeviNguyen/three_heavens/pull/44) (merged 2026-09-12).

**Classification:** Verified production-image preflight failure during local rehearsal, not a claim of a live production outage.

## Symptom and risk

The production-image preflight failed with `Gem::LoadError`. A production readiness check must run reliably in the same dependency environment as the app; otherwise it can block a safe release despite a healthy application implementation.

## Root cause

`bin/ops/preflight` loaded the `json` library before Rails' `config/boot` established Bundler's dependency constraints. Ruby therefore activated the default `json` gem (2.9.1) instead of the lockfile-selected `json` (2.21.2). Once activated, the wrong gem version could not be reconciled simply by booting Rails later.

## Correction

Remove the pre-Bundler JSON activation. Keep text and `--json` preflight output behavior unchanged, but ensure the Bundler environment is established first.

## Verification

PR #44 describes a **fresh-process** executable regression that checks the locked JSON specification is active *before* JSON loads. It also reports a successful production Docker build, all 13 production-image preflight critical checks healthy with four databases, `db:prepare`, and HTTP 200 for both `/up` and `/ready`.

## Lesson

**Boot order is part of correctness.** A check that passes in a long-running developer process can fail in a clean production image. For dependency activation bugs, a fresh-process test is stronger than unit tests that inherit an already-loaded environment.

**Interview angle:** Explain why the correct fix was a small change in boot sequence, not a dependency upgrade or relaxed version constraint.
