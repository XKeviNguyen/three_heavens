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
  corrective changes until the explicit CI gates below pass;
- merge a normal task Pull Request only after its base, final head commit, and
  explicit Pull Request CI gate have been verified;
- after merging, verify the resulting `develop` head and its push-triggered CI
  gate before deleting either temporary task branch;
- switch back to `develop`, fetch/prune, fast-forward it, delete the merged local
  task branch, verify the final green integration state, and report the result.

The default lifecycle is one assigned mega-task, one focused task branch, and
one Pull Request to `develop`. Tightly related subcomponents may share that
branch when they form one coherent architecture or product milestone.
Corrective commits remain on the same branch and Pull Request. Do not create
unrelated branches or begin the next product feature before the current Pull
Request is integrated. Stop after completing the assigned integration
milestone. The only exception is a focused corrective branch and Pull Request
needed to restore a task-caused post-merge `develop` CI failure as described
below; it remains part of the same integration milestone.

### Explicit Pull Request CI merge gate

Before Codex merges **any** normal task Pull Request into `develop`, Codex must
verify all of the following for the Pull Request's final head commit SHA:

1. The Pull Request base is exactly `develop`.
2. Each of these five GitHub Actions jobs exists for that exact final head SHA:
   `scan_ruby`, `scan_js`, `lint`, `test`, and `system-test`.
3. Each of those five jobs has completed with an explicit `success` conclusion.

This gate applies regardless of whether GitHub reports any checks as formally
required or whether branch protection/rulesets are enforced. “No required checks
configured” never permits a merge. An overall workflow badge, a result for an
earlier commit, or a stale check is not sufficient evidence.

Codex must not merge when any expected job is absent or has a status or
conclusion of `queued`, `pending`, `in_progress`, `cancelled`, `skipped`,
`timed_out`, `action_required`, `failure`, or anything other than explicit
`success`. Only explicit success for all five named jobs permits autonomous merge
into `develop`. Do not weaken CI to satisfy this gate.

### Post-merge `develop` CI gate

A task is not fully integrated merely because its Pull Request checks passed.
After merging, Codex must identify the resulting `origin/develop` HEAD (the merge
or integration commit SHA), wait for the push-triggered CI workflow for that
exact SHA, and verify that `scan_ruby`, `scan_js`, `lint`, `test`, and
`system-test` all exist and complete with explicit `success` conclusions.

The final integration invariant is a green `origin/develop` HEAD. If its
post-merge CI is absent, unfinished, or non-successful, do not touch `main` or
begin unrelated feature work. Inspect the actual failure. If the just-integrated
task caused it, create a focused corrective branch from current `develop`, fix,
validate, commit, push, open a Pull Request back to `develop`, satisfy the exact
five-job Pull Request gate, merge it, and repeat this post-merge verification.
For a pre-existing or external failure, do not alter unrelated work. If it cannot
safely be corrected within scope, preserve the state, stop, and report `develop`
as unhealthy rather than claiming completion.

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
the exact job-level results and actual logs; classify failures as task-caused,
pre-existing, or external/environmental. Fix task-caused failures, rerun relevant
local validation, commit, push, and re-check the explicit CI gates until they are
green. Never make CI green by weakening a quality gate: do not ignore scanner
failures, disable jobs, remove legitimate tests, skip system tests, add
`continue-on-error`, or suppress valid findings instead of correcting them.

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

Before declaring a normal coding mega-task complete, run the complete local
quality gate from the repository root:

```sh
bin/rails test
bin/rails test:system
bin/rubocop
bin/brakeman --no-pager
bin/bundler-audit
bin/importmap audit
git diff --check
bin/rails zeitwerk:check
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

## Terminal task report

GitHub is the authoritative review artifact. Do not generate mandatory review
or changes files in `~/Downloads`, and do not dump giant unified diffs there.

After every completed task, provide a concise terminal report containing:

- task summary;
- task branch, Pull Request number and URL, and commits;
- merge commit or final `develop` SHA;
- migrations and important architecture or security decisions;
- exact results for `scan_ruby`, `scan_js`, `lint`, `test`, and `system-test`
  on both the final Pull Request head and the post-merge `develop` push;
- remaining concerns and deferred follow-ups;
- confirmation that `main` was not modified, `.env` was not inspected, no
  unauthorized provider request occurred, and no persistent data or volume was
  destroyed.

## Engineering operating principles

### Prefer the smallest sufficient solution

Before adding code, abstractions, dependencies, configuration, state, or files,
inspect whether the existing implementation can be reused, simplified, or
corrected.

Remove dead, duplicated, unreachable, obsolete, or superseded code when doing
so is safe, directly related to the task, and reduces total complexity.

Prefer improving an existing clear abstraction over creating a parallel one.

Introduce a new abstraction only when it:

- represents a real domain concept;
- isolates a real external/infrastructure boundary;
- removes meaningful duplication; or
- makes an important invariant substantially easier to enforce or test.

Do not create speculative extension points, placeholder services, unused
configuration, generic frameworks for one concrete use case, or dependencies
without a current product requirement.

Prefer the smallest sufficient design, not merely the smallest textual diff.
A larger root-cause fix is preferable to a smaller workaround when it reduces
total complexity or prevents recurrence.

### Model the domain before substantial implementation

For non-trivial stateful behavior, determine before coding:

- authoritative state versus derived state;
- entities and ownership boundaries;
- valid and invalid state transitions;
- lifecycle and deletion rules;
- concurrency and idempotency assumptions;
- failure, retry, cancellation, and recovery semantics;
- cost and boundedness requirements.

In Rails, encode important invariants at the strongest practical layer:
PostgreSQL constraints and indexes, model validations, enums, immutable records,
value objects, and explicit service boundaries.

Do not represent an unclear state machine as scattered conditionals.

### Optimize the complete user flow

For user-facing behavior reason through:

user action
→ durable state change
→ asynchronous work if any
→ visible feedback
→ failure/retry behavior
→ cancellation
→ completion

Prefer predictable behavior, useful feedback, safe recovery, and stable UI
state over internal elegance that makes the actual product confusing or
fragile.

User experience never overrides correctness, privacy, security, data integrity,
or explicit provider-cost authorization.

### Preserve architectural boundaries

Keep responsibilities explicit:

- controllers: HTTP transport, authentication/authorization, parameter shape,
  and response selection;
- models and PostgreSQL: durable state and persistent invariants;
- services/forms: domain workflows and application orchestration;
- jobs: asynchronous execution, retries, and durable work boundaries;
- queries: bounded read/analytics logic;
- provider clients: external API behavior;
- operations services: process, filesystem, backup, restore, and infrastructure
  boundaries.

Do not duplicate authoritative state across layers without a clear reason.
Do not leak provider, queue, filesystem, or deployment implementation details
into unrelated domain APIs.

### Fix root causes and prove behavior

For defects:

1. reproduce or precisely reason about the failure;
2. identify the violated invariant or root cause;
3. fix it at the correct architectural boundary;
4. add deterministic regression coverage;
5. inspect adjacent paths that depend on the same invariant.

Do not hide deterministic failures with sleeps, arbitrary retries, oversized
queues, catch-all rescue blocks, disabled checks, or special-case bypasses.

Distinguish evidence precisely:

- implemented;
- unit tested;
- integration tested;
- CI verified;
- runtime verified;
- production verified.

Never claim a stronger level of verification than was actually performed.

When the real runtime path cannot safely be exercised, state exactly what was
tested and what remains unverified.

### Minimize cognitive load

Prefer straightforward control flow, descriptive domain names, local reasoning,
explicit ownership, focused methods, limited mutation, and comments that
explain why.

Avoid clever code, premature genericization, unnecessary wrapper layers, hidden
side effects, and abstractions that increase rather than reduce reader load.

### Final simplification review

Before finalizing a coding Pull Request, inspect the diff and ask:

- Can newly added code be removed or simplified?
- Did this change create duplicate concepts or state?
- Is every new abstraction currently justified?
- Is every new dependency/configuration currently consumed?
- Is the root cause actually fixed?
- Is the user flow correct?
- Are important invariants encoded and regression-tested?
- What exact evidence proves the behavior works?

Do not refactor unrelated code merely for aesthetic cleanup.

The objective is minimum necessary complexity, not minimum line count.
