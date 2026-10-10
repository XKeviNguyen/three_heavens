# Case 03 — Request-body concurrency exhausted container memory

**Evidence:** [PR #68 — Bound memory for many simultaneous request bodies](https://github.com/XKeviNguyen/three_heavens/pull/68) (merged 2026-10-02).

**Classification:** Reproduced P1 issue in a production-image test under controlled limits, **not** a reported public-site outage.

## Symptom and risk

With a 768 MiB memory limit and no swap, 80 concurrent signed-out requests with 30 MiB chunked bodies OOM-killed Puma. A 21 MiB per-request cap existed, but it did not bound the *aggregate* cost of numerous in-flight connections. At the kill, the investigation measured about 404 MiB of process memory, 268 MiB of kernel socket buffers and 120 MiB of dirty temporary-file pages.

## Root cause

Puma began consuming request bodies for multiple connections **before** application-level rejection. Bounding a single body is different from bounding many simultaneous bodies. The investigation explicitly ruled out Thruster as the root cause.

## Correction

- Configure jemalloc via `MALLOC_CONF="dirty_decay_ms:0,muzzy_decay_ms:0"` to release freed pages promptly.
- Bound TCP receive/send buffer maximums to 256 KiB through Docker/Kamal per-container `net.ipv4.tcp_rmem` and `net.ipv4.tcp_wmem` sysctls.
- Both controls were required; either alone still allowed the 200-connection test to OOM.

## Verification

PR #68 reports that 80 and 200 simultaneous chunked requests, slow senders, malformed framing, disconnects, and content-length floods no longer OOM-killed the same running Puma process. Ten waves of 80 requests kept measured process memory between 168–238 MiB. Legitimate login requests continued to succeed during the load. Deployment contract tests now cover both controls.

## Remaining trade-offs

Connection memory still scales with connection count; thousands of connections require limits at the edge. Under sustained load, rejected requests may present as 502/reset rather than a clean 413. The sysctls are not automatically valid for host-network containers.

## Lesson

**A per-request limit is not a concurrency limit.** Model the full resource budget (user space, kernel buffers and temporary files), reproduce with the real container and network mode, and retain a repeatable stress harness.

**Interview angle:** Show why tuning an allocator alone did not solve the problem.
