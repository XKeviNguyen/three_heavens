# Case 01 — A backup that could not be restored

**Evidence:** [PR #64 — Fix V1.1 recovery, autosave, and idempotency blockers](https://github.com/XKeviNguyen/three_heavens/pull/64) (merged 2026-09-29).

**Classification:** P1 defects reproduced during release/audit testing. Not presented as a real production data-loss incident.

## Symptom and risk

A database dump could be created successfully, but restoring it failed if it contained methodology-profile or translation-reference revisions. The relevant constraints called digest functions and raised `function digest(text, unknown) does not exist`. A separate restore path also failed for non-UTF-8 bytes in stored attachments (PDF/DOCX or other binary objects). A backup that exists but cannot be restored is not a useful recovery plan.

## Root cause

`pg_dump` / `pg_restore` operate with `search_path = ''` during restoration. Inline `CHECK` constraints evaluated during `COPY` invoked PostgreSQL functions using unqualified `digest()` from pgcrypto; that name could no longer be resolved in the restore context. A different extractor passed binary storage through a text-mode file, allowing UTF-8 decoding assumptions to corrupt or reject arbitrary bytes.

## Correction

- Migration `20260929120000` replaced the digest implementation with `pg_catalog.sha256(pg_catalog.convert_to(value, 'UTF8'))` and schema-qualified table references.
- It verified pre-existing stored digests before committing; simply changing a function definition would not automatically revalidate existing rows.
- Restore verification was organized into `pre-data`, `data`, and `post-data` phases, with narrowly scoped compatibility for older backup bundles.
- The storage extractor was changed to binary-mode output.

## Evidence and verification

PR #64 documents comparison of SHA-256 results over Unicode, emoji, combining marks, backslashes, and 200 KB strings; database restore checks; an every-byte-value storage round trip; and a disposable restore drill that compares public tables row-for-row and reads records through Rails.

## Lesson

**A successful backup command does not prove recoverability.** Test the full restore in an isolated target, using representative non-empty records and binary attachments. Database functions involved in constraints or triggers must not rely on an ambient `search_path`.

**Interview angle:** Explain the difference between *backing up bytes* and *proving application-level recovery*.
