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

## Autonomous Git and Pull Request workflow

Every explicitly assigned implementation task authorizes its complete normal
Git and Pull Request lifecycle. The user does not need to separately authorize
routine branch creation, staging, commits, task-branch pushes, Pull Request
operations, task-caused corrective commits, merging a green task Pull Request
into `develop`, or deleting its successfully merged temporary branch.

For each assigned implementation task, Codex is authorized by default to:

- inspect repository state and fetch/prune `origin`;
- switch to `develop`, fast-forward it from `origin/develop`, and create exactly
  one focused `feature/*`, `fix/*`, or `chore/*` task branch from current
  `develop`;
- modify only files within the assigned scope, run required migrations, and run
  appropriate tests and quality gates;
- stage task-related files and create one or more sensible professional commits;
- push the task branch and create a GitHub Pull Request whose base is exactly
  `develop`;
- write or update the Pull Request title and description, inspect its status and
  GitHub Actions logs, and diagnose failures;
- fix task-caused implementation or CI failures, validate, commit, and push
  corrective changes until all required checks pass;
- after verifying the base is exactly `develop`, merge the green Pull Request
  using the repository's normal non-force merge strategy and delete its remote
  task branch;
- switch back to `develop`, fetch/prune, fast-forward it, delete the merged local
  task branch, verify the final state, and report the integration result.

The default lifecycle is one assigned mega-task, one focused task branch, and
one Pull Request to `develop`. Tightly related subcomponents may share that
branch when they form one coherent architecture or product milestone.
Corrective commits remain on the same branch and Pull Request. Do not create
unrelated branches or begin the next product feature before the current Pull
Request is integrated. Stop after completing the assigned integration
milestone.

Before editing, review `git status --short` and preserve all pre-existing or
unrelated changes. Never use destructive Git commands to remove local work.
At handoff, report the current branch and complete `git status --short`.

## Integration and release branch safety

`develop` is the GitHub default and normal integration branch. All ordinary
Codex task branches and Pull Requests target `develop`.

`main` is the protected conceptual release/stable branch. Codex must never:

- push directly to `main` or create a normal feature Pull Request targeting it;
- merge a Pull Request into `main` or run `gh pr merge` when its base is `main`;
- change `main` to point at `develop`, or reset, rebase, force-update, or delete
  `main`;
- alter `main` merely to make development more convenient.

If a task unexpectedly targets `main`, stop instead of merging. The only
intended path into `main` is a future human-controlled `develop` to `main`
release after external audit, even when all CI checks are green.

Never force-push or rewrite published shared history. Never delete or reset
databases, schemas, Docker volumes, user data, or other persistent data without
explicit approval.

## Unattended execution and CI ownership

Assume the user may leave an assigned mega-task unattended for several hours.
Use the repository architecture, tests, these instructions, and professional
engineering judgment for routine implementation and Rails design choices.
Continue through validation, Pull Request creation, task-caused correction, and
safe integration into `develop` without pausing for routine decisions.

Stop early only for a genuine blocker, such as an unavailable required secret,
an unauthorized paid provider request, a required destructive persistent-data
operation, unavailable GitHub permission, an unsafe external infrastructure
action, material ambiguity that risks data loss or security, or unrelated local
work that would have to be overwritten. Preserve state and report the blocker
precisely.

Codex owns failures caused by the task. After opening the Pull Request, inspect
required checks and their actual logs; classify failures as task-caused,
pre-existing, or external/environmental. Fix task-caused failures, rerun relevant
local validation, commit, push, and re-check CI until it is green. Never make CI
green by weakening a quality gate: do not ignore scanner failures, disable jobs,
remove legitimate tests, skip system tests, add `continue-on-error`, or suppress
valid findings instead of correcting them.

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
