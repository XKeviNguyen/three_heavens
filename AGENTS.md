# Three Heavens engineering instructions

## Scope and precedence

This file contains the permanent repository-wide instructions for Codex when
working on Three Heavens. Follow more specific `AGENTS.md` files for files in
their subtrees when they exist. Direct user instructions take precedence over
this file.

Three Heavens is a professional Rails 8.1 application backed by PostgreSQL 17.
Development moves quickly with Codex assistance, but speed must not come at the
expense of security, correctness, maintainability, or production readiness.

## Working principles

- Security comes first in every environment, including local development.
- Work on one focused feature branch at a time.
- Keep every change within the requested scope. Do not start unrelated features
  or opportunistic refactors.
- Prefer maintainable, production-quality code over prototypes or throwaway
  implementations.
- Inspect the existing code, tests, conventions, and current worktree before
  changing files.
- Preserve user-authored and pre-existing changes. Do not overwrite, revert, or
  clean up changes that are outside the current task.
- When an improvement is useful but outside scope, record it as a deferred
  follow-up instead of implementing it.
- Explain important architectural decisions and tradeoffs in the final report.
- Do not claim that work is complete when required validation is failing.

## Git and destructive-action safety

- Never stage, commit, push, merge, rebase, force-push, or delete branches unless
  the user explicitly authorizes that exact action.
- Do not switch branches or create additional branches unless explicitly asked.
- Never delete or reset databases, schemas, Docker volumes, user data, or other
  persistent data without explicit approval.
- Do not use destructive Git commands to remove local changes.
- Before editing, review `git status --short` and account for unrelated changes.
- At handoff, report the current branch and the complete `git status --short` so
  pre-existing and task-related changes remain visible.

## Secrets and secure development

- Never hard-code credentials, API keys, tokens, private keys, passwords, or
  other secrets.
- Never modify `.env` or any environment-secret file unless explicitly
  instructed.
- Do not read, print, copy, or inspect `.env` contents unless the task explicitly
  requires it and the user has authorized doing so. Prefer using environment
  variables without exposing their values.
- Never expose secrets in logs, command output, diffs, fixtures, tests,
  screenshots, generated review files, or final reports.
- If a secret-like value is unexpectedly encountered, do not repeat it. Redact
  it in all output and notify the user without revealing the value.
- Never disable TLS or SSL certificate verification.
- Use Rails credentials, environment variables, or the project's established
  secret-management mechanism. Commit only safe placeholders or documented
  variable names.
- Treat local development data and services with the same security care as
  production systems.
- Avoid logging sensitive request bodies, provider payloads, personal data, and
  authentication material.

## Rails application design

- Follow established Rails 8.1 conventions and the patterns already present in
  the repository.
- Keep controllers thin: handle transport concerns, authorization, parameter
  validation, and response selection there; place business workflows in the
  appropriate model, service, query, form, or job object.
- Keep models cohesive. Do not turn Active Record models into catch-all service
  layers.
- Put external API and provider integrations in clearly and appropriately
  namespaced service classes.
- Make provider boundaries explicit so external behavior can be tested with
  fakes or stubs and changed without spreading provider-specific logic through
  the application.
- Use background jobs for slow operations and external AI calls. Keep jobs
  idempotent where practical, pass stable identifiers rather than large object
  graphs, and define deliberate retry and failure behavior.
- Handle expected failures explicitly. Do not silently swallow exceptions or
  expose internal/provider error details to end users.
- Add or update tests for behavior changes, regressions, authorization rules,
  failure cases, and important boundary conditions.

## PostgreSQL and migrations

- PostgreSQL 17 is the source of truth for production data behavior; do not
  introduce assumptions that only work with SQLite or another database.
- Never modify a migration that has already been merged. Create a new migration
  for every subsequent schema change.
- Use PostgreSQL constraints and indexes in addition to Rails validations when
  data integrity, uniqueness, referential integrity, or query performance
  requires them.
- Prefer reversible migrations. For irreversible operations, document the
  reason and provide a deliberate rollback strategy when possible.
- Consider locks, table size, existing rows, nullability, defaults, index-build
  behavior, and deployment order before making schema changes.
- Do not delete, truncate, reseed, or otherwise destroy database data without
  explicit approval.

## AI and external providers

- Never make any real paid external API request, including a manual smoke test,
  unless the user explicitly authorizes that specific request.
- Do not make real paid API requests from automated tests. Stub or fake provider
  boundaries with deterministic local responses.
- Do not store hidden chain-of-thought, private reasoning, or similar internal
  reasoning text returned by AI providers.
- Avoid retaining raw provider responses unless a concrete product, debugging,
  audit, or compliance requirement justifies it. Store only the minimum data
  required, with appropriate filtering and retention.
- Validate and constrain provider inputs and outputs. Treat model output and
  remote API data as untrusted.
- Make timeouts, retry limits, idempotency, rate limits, and user-visible failure
  behavior explicit for external calls.
- Never place provider credentials or sensitive payloads in job arguments,
  logs, test snapshots, or review artifacts.

## Validation and quality gate

Before declaring a coding task complete, run all of the following from the
repository root:

```sh
bin/rails test
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
git diff --check
```

If the task creates one or more migrations, also run:

```sh
bin/rails db:migrate
bin/rails db:migrate:status
```

- Record the exact outcome of every required command, including failures.
- Never describe a check as passing if it was not run, did not finish, or failed.
- If a check cannot run because of the environment, report it as not run or
  blocked, explain why, and do not claim full success.
- Fix failures caused by the current task when doing so remains in scope.
- Do not alter unrelated code merely to make a broad check pass. Report
  unrelated failures separately.
- A direct user instruction may add or narrow checks for a non-coding task; make
  that task-specific validation explicit in the final report.

## Required review handoff

After every completed implementation task, automatically create two review
files outside the Git repository under `~/Downloads`. Derive a filesystem-safe
slug from the current branch by replacing path separators and unsafe characters
with underscores.

Create exactly:

1. `three_heavens_<branch_slug>_review.md`
2. `three_heavens_<branch_slug>_changes.md`

The review file must include:

- current branch
- scope
- architecture summary
- important design decisions
- files created/modified
- migrations/schema changes
- security decisions
- external API behavior when relevant
- background jobs when relevant
- retry/error handling when relevant
- tests added/modified
- exact quality-gate results
- `git status --short`
- `git diff --stat`
- concerns
- tradeoffs
- assumptions
- deferred follow-ups
- manual smoke-test instructions when relevant
- explicit confirmation whether `.env` or secrets were touched

The changes file must include:

- unified diffs for tracked, modified files relevant to the task
- full contents of relevant newly created or untracked source files
- full contents of new migrations
- full contents of new tests

Never include any of the following in either review file:

- `.env` contents
- credentials, API keys, tokens, passwords, or private keys
- logs
- `tmp` or cache files
- vendor or dependency directories
- irrelevant generated artifacts

If secret-like content is unexpectedly encountered while generating the review
files, redact it instead of copying it. Include only task-relevant changes; do
not include unrelated worktree changes in the changes file.

At the end of every completed task, print the exact absolute paths to both
review files so the user can upload them to ChatGPT for independent review.
