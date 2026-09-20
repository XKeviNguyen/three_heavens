# Disaster recovery

## Invariants

1. The primary PostgreSQL database and Active Storage tree are the authoritative user-data recovery set.
2. Every durable Document source attachment must have its storage object after restore.
3. Solid Cache and Solid Cable state may be recreated.
4. Solid Queue is rebuilt empty; stale queue state is not replayed.
5. Application boot and restore verification issue no provider requests.
6. Automatic reconciliation resumes only pipeline work already covered by durable launch authorization.
7. Failed provider work is retried only through the existing explicit owner action.
8. The old environment is fenced before a restored environment can be promoted.

## Recovery procedure

1. Fence the failed environment: stop its web and worker processes and revoke its ability to issue provider requests. Confirm there cannot be two active environments using the same provider authorization. A remote provider request may continue briefly even after the local process disappears; wait for or account for that uncertainty before any owner retry.
2. Select a completed off-host bundle and run `bin/ops/restore-verify` against disposable targets first. Do not proceed if the bundle, dump catalog, extraction, schema, or integrity audit fails.
3. Provision fresh primary, cache, queue, and cable databases. Restore only the verified primary dump. Apply the repository's current cache, queue, and cable schemas to their empty databases through the normal Rails database preparation process for the exact restored release. Do not load an old queue snapshot.
4. Restore the verified storage tree to a newly provisioned persistent volume and preserve ownership/writability for uid/gid 1000.
5. Boot the exact compatible application release in a **quiescent verification state** with provider egress still fenced. Set `SOLID_QUEUE_IN_PUMA=false`, do not run a separate Solid Queue worker/supervisor, and do not start recurring scheduling. Boot alone must not enqueue provider work.
6. While quiescent, run restore integrity verification, `/up`, `/ready`, safe system diagnostics, and primary-state inspection. `bin/rails ai:reconcile_stale` may be run only when deliberately chosen after the configured stale threshold; it is bounded, idempotent, uses generic reason codes, preserves lineage and completed results, and never calls OpenRouter.
7. After operator review, enable the normal Solid Queue supervisor/worker and recurring topology. `bin/rails pipelines:reconcile` may advance already-authorized durable pipeline state, but only after old-environment fencing is confirmed. It does not create new launch authorization. Owners explicitly decide whether to retry failed runs and incur further provider cost.
8. Promote through the organization's separate human-controlled infrastructure procedure only after verification. This repository performs no DNS, firewall, database promotion, or Kamal deploy automatically.

## Primary run states after queue loss

- `pending`: the scheduled queue job is unknown and is not replayed. Once stale it becomes `stale_pending`; a delayed job from the old lineage cannot claim after state or `scheduled_job_id` changes.
- `running`: the provider call may have been interrupted or may still exist remotely. Once fenced and stale it becomes `stale_execution`. Late results can update only the exact current execution attempt.
- `failed`: remains failed. Only the authenticated owner may use the existing explicit retry action, which creates a new scheduling lineage and cost warning.
- `completed`: remains authoritative and is never recomputed or overwritten by DR reconciliation.

The queue database is therefore operational coordination, not the source of truth for paid work. Restoring it would weaken the execution-claim boundary and is not the default recovery method.
