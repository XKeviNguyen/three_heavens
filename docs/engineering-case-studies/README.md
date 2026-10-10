# Three Heavens — Engineering Case Studies

Real debugging and engineering decisions from the [Three Heavens](https://github.com/XKeviNguyen/three_heavens) repository, written for technical review and interviews.

**Evidence standard:** Every completed case links to a merged pull request describing the observed failure, diagnosed cause, correction, and verification. An audit reproduction or production-image test is **not** described as a real customer-facing production incident. PR descriptions and their associated code/tests are the source of record; the summaries below do not replace them.

| Case | Failure investigated | Engineering focus | Evidence |
| --- | --- | --- | --- |
| [01 — PostgreSQL restore and binary fidelity](01-postgresql-restore-and-binary-fidelity.md) | Valid backup could not be restored | Database constraints, backup/restore | [PR #64](https://github.com/XKeviNguyen/three_heavens/pull/64) |
| [02 — Lost-response autosave](02-autosave-lost-response.md) | A lost acknowledgement could lead to a later edit being lost | Concurrency, distributed state, idempotency | [PR #64](https://github.com/XKeviNguyen/three_heavens/pull/64) |
| [03 — Concurrent request OOM](03-concurrent-request-memory.md) | Request-body flood killed the application under a memory cap | Performance, resource limits, security | [PR #68](https://github.com/XKeviNguyen/three_heavens/pull/68) |
| [04 — Bundler boot order](04-bundler-boot-order.md) | Production-image preflight failed with `Gem::LoadError` | Dependency isolation, boot order | [PR #44](https://github.com/XKeviNguyen/three_heavens/pull/44) |
| [05 — Turbo system-test races](05-turbo-system-test-races.md) | Post-merge system test intermittently navigated to the wrong page | Async UI, deterministic testing | [PR #70](https://github.com/XKeviNguyen/three_heavens/pull/70) |
| [06 — Session invalidation](06-server-side-session-invalidation.md) | A copied cookie stayed usable after sign-out | Authentication, revocation | [PR #69](https://github.com/XKeviNguyen/three_heavens/pull/69) |
| [07 — Stale source import responses](07-async-source-import-ownership.md) | Older import responses could supersede newer edits | Async ownership, ordering, data loss | [PR #77](https://github.com/XKeviNguyen/three_heavens/pull/77) |

## How to use these in an interview

Explain the **symptom → root cause → design decision → reproducible verification → trade-off** in your own words. For each case, the linked PR is the primary evidence; distinguish observed behavior from a hypothetical exploit and a local production-image reproduction from an outage in the deployed application.

## Boundaries

- These are historical case studies, not a current production security or uptime certification.
- Results and test counts are those reported in the linked PRs at their respective commits, not claims about the latest deployment.
- Open findings (for example, the Cloudflare Tunnel client-IP follow-up in [PR #87](https://github.com/XKeviNguyen/three_heavens/pull/87)) are excluded from the *resolved* case list until their completion and verification are independently established.
- No personal data, secrets, real credentials, or production dumps are included.
