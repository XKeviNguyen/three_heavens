# Production backup and restore

## Authoritative recovery set

The authoritative Three Heavens recovery set is the primary PostgreSQL database plus the complete Active Storage Disk tree mounted at `/rails/storage`. The primary database contains user and workflow records, durable provider-run lineage, Pipeline Events, and Active Storage attachment metadata. The storage tree contains the bytes for private uploaded sources.

Solid Cache and Solid Cable contain derived or transient state and are rebuilt from their schemas. Solid Queue is special operational state and is deliberately excluded from the default bundle; restoring an old queue snapshot could replay jobs that no longer agree with primary state. Queue recovery is covered in [disaster-recovery.md](disaster-recovery.md).

## Bundle format version 1

Each completed directory has a collision-resistant timestamp/random identifier and exactly these artifacts:

```text
<backup-id>/
  manifest.json
  primary.dump
  storage.tar.gz
  COMPLETE
```

`primary.dump` is a PostgreSQL custom-format dump. `storage.tar.gz` preserves Disk-service relative object paths and bytes. `manifest.json` contains the format/version, UTC timestamp, safe release SHA when supplied through `KAMAL_VERSION` or `RELEASE_SHA`, primary schema version, artifact SHA-256 values and byte sizes, and aggregate storage file/byte counts. It contains no connection URL, credential, filename, user identity, prompt, source, translation, or provider body. `COMPLETE` contains the manifest checksum.

Directories and files are created with modes 0700 and 0600 where supported. Work happens beneath a hidden `.partial-<backup-id>` directory. The database dump, storage archive, manifest, and completion marker are closed and flushed before an atomic rename exposes the final bundle. A failure removes any completion marker and leaves no valid completed bundle.

## Create a backup

Run from a production application container or an equivalent trusted operator environment with `DATABASE_URL` and the configured local Active Storage root available:

```sh
bin/ops/backup /absolute/path/to/backup-root
```

The command rejects an empty/relative/dangerous destination, the application root and every descendant, the live storage root and every descendant, symlink path components, and collisions. **Never store a backup bundle inside `/rails/storage` or a descendant.** A production local staging destination must be a separately mounted path or an equivalent trusted operator filesystem, followed by an encrypted off-host copy. It invokes `pg_dump` using `PGDATABASE` in the child environment, never a credential-bearing command argument. Normal output contains only the backup ID and completed bundle path.

The database dump is taken before the storage archive. Active Storage writes object bytes before committing attachment metadata. Durable Document attachments are immutable in normal product behavior and Documents are not destructively deleted; consequently every durable file referenced by the database snapshot is present when the subsequent storage archive walks the tree. A concurrently abandoned SourceImport may leave an extra unreferenced object or may be absent; the integrity audit classifies temporary staging separately. Unreferenced extra files are recoverable warnings, while a missing durable Document source is critical.

`pg_dump` covers the complete primary schema and data, including `ai_provider_attempts`, owner/lineage foreign keys and triggers, immutable revision/version history, and Active Storage attachment references. The storage archive covers the corresponding private object tree. Temporary SourceImports, one-time workspace submissions, and unattached blobs may legitimately disappear through their documented maintenance schedules; durable Document attachments and translation history do not. Restore verification requires the exact schema version, so a bundle cannot silently omit this milestone's constraints or trigger functions.

A local completed bundle is not sufficient disaster protection. Copy it promptly to an independent, access-controlled, encrypted off-host backup system using the organization's approved tooling. This repository deliberately does not invent encryption or perform a cloud upload.

## Retention

Retention is dry-run by default and recognizes only fully valid Three Heavens bundles directly beneath the explicit root:

```sh
bin/ops/backup-prune /absolute/path/to/backup-root --keep-last 14 --older-than-days 30 --dry-run
bin/ops/backup-prune /absolute/path/to/backup-root --keep-last 14 --older-than-days 30 --execute
```

When both policies are present, the newest N bundles are protected and only older remaining bundles past the age threshold are selected. Incomplete directories, unrelated files, malformed bundles, and symlinks are preserved. Never point this at `/` or a general-purpose directory.

## Isolated restore verification

Create a new empty PostgreSQL database and choose a new or empty absolute storage directory. Neither may be the currently running application destination.

```sh
export RESTORE_DATABASE_URL='postgresql://RESTORE_USER:RESTORE_PASSWORD@RESTORE_HOST/NEW_EMPTY_DATABASE'
export RESTORE_STORAGE_PATH='/absolute/path/to/new-empty-restore-storage'
bin/ops/restore-verify /absolute/path/to/backup-root/BACKUP_ID
```

The command performs these phases in order:

1. strictly parses the bounded manifest and requires the completion marker;
2. verifies fixed artifact names, sizes, SHA-256 checksums, and `pg_restore --list`;
3. refuses a missing, non-empty, or detectably live database target;
4. refuses a missing, non-empty, live, relative, or unsafe storage target;
5. restores the primary dump with `pg_restore --exit-on-error` and no ownership/ACL replay;
6. extracts only regular files/directories, rejecting absolute paths, traversal, duplicates, links, special entries, and symlink parents;
7. audits the restored schema, blobs, attachments, durable Document sources, temporary SourceImports, missing objects, and unreferenced objects in bounded batches.

Success requires the restored schema version to equal the backed-up version and zero critical integrity problems. Normal output is aggregate-only. No migrations, provider calls, promotion, DNS change, deployment, or replacement of `/rails/storage` occurs.

For a recurring drill, provision a disposable empty PostgreSQL database and temporary storage directory, run the same command, record the aggregate outcome, then destroy only those drill resources under the operator's normal database lifecycle controls. Never substitute a development or production database.

Developers and CI operators can exercise the complete path against two uniquely named disposable local databases plus temporary filesystem roots:

```sh
ALLOW_DISPOSABLE_RESTORE_DRILL=1 RAILS_ENV=test bin/ops/restore-drill-local
```

The guard refuses production and requires the exact confirmation variable. It creates representative synthetic data with a Document attachment, builds a real `pg_dump` bundle, restores through real `pg_restore`, verifies record and byte survival plus the integrity audit, and removes only databases bearing its random `three_heavens_restore_drill_...` prefix. It never targets the normal test, development, or production database and never calls a provider.
