# Three Heavens

**An AI-assisted translation workspace where several models translate the same text, other models review and judge the results without knowing who wrote them, and a human editor makes the final call.**

[![CI](https://github.com/XKeviNguyen/three_heavens/actions/workflows/ci.yml/badge.svg?branch=develop)](https://github.com/XKeviNguyen/three_heavens/actions/workflows/ci.yml)
![Ruby 3.4](https://img.shields.io/badge/Ruby-3.4-CC342D?logo=ruby&logoColor=white)
![Rails 8.1](https://img.shields.io/badge/Rails-8.1-D30001?logo=rubyonrails&logoColor=white)
![PostgreSQL 17](https://img.shields.io/badge/PostgreSQL-17-4169E1?logo=postgresql&logoColor=white)
![Hotwire](https://img.shields.io/badge/Hotwire-Turbo%20%2B%20Stimulus-5A2D82)
![Docker + Kamal](https://img.shields.io/badge/Deploy-Docker%20%2B%20Kamal-2496ED?logo=docker&logoColor=white)

It is built for translators of long-form texts — sermons, articles, books — who want more than one AI opinion, need terminology to stay consistent, and must stay responsible for the final wording. You paste or upload a document and add the terms that must not change. Several models translate it independently. Reviewer models score the anonymous candidates, judge models rank them, and you edit the winner, optionally with AI suggestions, before approving a final version. AI never finalizes anything on its own.

![Judging page: average judge scores as a gauge for all models and a tile per model, above the winning Japanese translation of an English sermon](docs/images/readme/04-judging.png)

The interface is available in English, Vietnamese, and Japanese. New to the app? Start with the [user guide](docs/user-guide.md).

> **About the screenshots.** They come from the real application running locally against a throwaway database. All names, texts, scores, token counts, and costs are **synthetic demo data** from a deterministic fake AI client ([`bin/capture-readme-screenshots`](bin/capture-readme-screenshots)). No AI service was called.

**Contents** — Product: [What it does](#what-it-does) · [Product tour](#product-tour) · [Using the app](#using-the-app) — Engineering: [Key design decisions](#key-design-decisions) · [Architecture](#architecture) · [Translation workflow](#translation-workflow) · [Data model](#data-model) · [Reliability](#reliability) · [Security](#security) · [Testing](#testing-and-release-quality) · [Tech stack](#tech-stack) · [Run it locally](#run-it-locally) · [Project structure](#project-structure) · [Deployment](#deployment) · [Engineering case studies](docs/engineering-case-studies/README.md) · [Status](#status-and-limitations)

## What it does

| Step (as named in the app) | What happens | Who decides |
| --- | --- | --- |
| **New translation** | Paste text or upload TXT, Markdown, DOCX (pictures kept), or text PDF, up to 21 MiB. Add a glossary, approved reference translations, and a methodology (style guide). | You |
| **Translation** | 1–6 models each write their own translation (at least 2 to continue to review and judging). Long texts are split into parts that all run at once. | AI, in parallel |
| **Blind review** | Reviewer models, picked from the whole OpenRouter catalog, score every candidate on faithfulness, naturalness, terminology, and instructions — under anonymous labels. The page shows each model's average score. | AI |
| **Judging** | Judge models rank the anonymous candidates; the rankings are combined into one winner. A failed reviewer or judge can be replaced with another model. | AI |
| **Human editor** | The winner becomes version 1 of your draft. Edit it, ask for AI suggestions, apply or ignore them, restore older versions. | You |
| **Finalize** | Approve a version and download it as TXT or DOCX. | You |

Each step can be started by hand, or a saved **workflow setup** runs translation → review → judging (→ optional AI suggestions) automatically and then stops at the editor. A **Benchmarks** page compares models across your own translations (wins, review and judge scores, cost, response time). It describes past results; the app makes no claim that competing models produce better translations in general.

## Product tour

<table>
<tr>
<td width="50%"><img src="docs/images/readme/01-new-translation.png" alt="New translation form: English to Japanese, a pasted sermon, the 'Japanese Sermon Terms' glossary selected, and three demo models chosen"></td>
<td width="50%"><img src="docs/images/readme/02-translation-candidates.png" alt="Translation candidates: each model's Japanese translation with its cost"></td>
</tr>
<tr>
<td><b>1. Start a translation.</b> Pick languages, paste or upload the source, choose a glossary, and search the OpenRouter catalog for several models. The form autosaves to the server about a second after you stop typing.</td>
<td><b>2. Compare independent candidates.</b> Every model translates the same source with the same instructions; nothing is merged or hidden.</td>
</tr>
<tr>
<td><img src="docs/images/readme/15-long-document-parts.png" alt="A long document translating in parts: Lumen shows 5 of 8 parts done and Quill 0 of 8, both running"></td>
<td><img src="docs/images/readme/03-blind-review.png" alt="Blind review page opening with average review scores: a gauge for all models and a tile per model with its distance from the average"></td>
</tr>
<tr>
<td><b>3. Long documents run in parts.</b> A text over 4,000 characters is split at paragraph and sentence boundaries; every part of every model is sent at once, and the counter shows finished parts (<a href="#long-documents-parts-and-parallel-work">why</a>).</td>
<td><b>4. Blind review with average scores.</b> Reviewers see anonymous labels, never model names. The page opens with the average of all candidates and of each model, highest first; it updates as reviewers finish.</td>
</tr>
<tr>
<td><img src="docs/images/readme/16-replace-failed-reviewer.png" alt="A failed reviewer card with error code structured_output_unavailable, and the open Replace panel showing who pays and Scholar (demo) selected as the new reviewer"></td>
<td><img src="docs/images/readme/14-score-board.png" alt="After the replacement: average scores from three reviewers, and a line saying Echo failed and was replaced by Scholar"></td>
</tr>
<tr>
<td><b>5. Replace a failed reviewer.</b> The card explains the error. Pick another model from the catalog: it reviews the same anonymous candidates, and only its work is billed, to the payer shown.</td>
<td><b>6. The round carries on.</b> The failed run stays in the history with its own cost; averages and judging use only the current reviewers. Judges can be replaced the same way.</td>
</tr>
<tr>
<td><img src="docs/images/readme/13-japanese-judging.png" alt="Judging page in the Japanese interface showing average judge scores and the winning translation"></td>
<td><img src="docs/images/readme/05-final-editor.png" alt="Final translation workspace: source, instructions, and glossary on the left; the editable Japanese draft (version 1) on the right"></td>
</tr>
<tr>
<td><b>7. Judging</b> (shown in the Japanese interface). Each judge ranks every candidate; ranking points are summed across judges, so the winner can differ from the highest average. No winner is declared until every current judge finishes.</td>
<td><b>8. You edit the winner.</b> Source, instructions, glossary, and review evidence stay beside the editor. Saving changed text creates a new version.</td>
</tr>
<tr>
<td><img src="docs/images/readme/06-ai-suggestion.png" alt="An AI suggestion for version 1, marked Ready to apply, with a suggested translation, change summary, and terminology notes"></td>
<td><img src="docs/images/readme/07-workflow-setup.png" alt="Workflow setup 'Sunday sermon workflow' listing translator, reviewer, judge, and suggestion models"></td>
</tr>
<tr>
<td><b>9. AI suggests, you decide.</b> A suggestion is tied to the exact version it was made for and is applied only when you click <i>Apply suggestion</i>.</td>
<td><b>10. Save a workflow setup</b> once: which models translate, review, judge, and suggest.</td>
</tr>
<tr>
<td><img src="docs/images/readme/08-automatic-approval.png" alt="Automatic mode selected with the saved workflow setup and a cost-approval checkbox"></td>
<td><img src="docs/images/readme/09-automatic-workflow.png" alt="Automatic workflow page reading 'Ready for you to edit' with a timeline of finished steps"></td>
</tr>
<tr>
<td><b>11. Run it automatically</b> on a second text ("Advent devotional"). You approve the AI requests for each translation before anything is sent.</td>
<td><b>12. It always stops for you.</b> The run ends at "Ready for you to edit": nothing applied, nothing finalized.</td>
</tr>
<tr>
<td><img src="docs/images/readme/11-translation-history.png" alt="Translation history with the translations, their winners, and AI cost"></td>
<td><img src="docs/images/readme/10-glossary.png" alt="The 'Japanese Sermon Terms' glossary with its preferred terms"></td>
</tr>
<tr>
<td><b>13. History</b> keeps every translation, its winner, and its AI cost, marked partial if a step did not report cost.</td>
<td><b>14. Glossaries</b> keep the terms that must not change; each translation records the exact revision it used.</td>
</tr>
</table>

Also captured: [the editor on a phone](docs/images/readme/12-mobile-final-editor.png).

## Using the app

1. Sign in, then choose who pays for AI work under **AI settings**: your own OpenRouter key, or platform-managed AI once an administrator allows it (Admin → Users). Saving a key checks it with OpenRouter and shows whether it works and its credit limit. Administrators set the platform's own key under **Admin → AI key**, without a redeploy.
2. **New translation:** choose languages, paste or upload the source (up to 21 MiB), add guidance, pick models or a workflow setup, and start.
3. **Candidates:** each model's card shows its translation and cost; a long document shows how many of its parts are done.
4. **Blind review:** search the OpenRouter catalog for reviewer models. They do not have to be the models that translated. Only models that can return structured answers (marked *Structured*) are offered for reviewing, judging, and suggestions, and the server refuses any other; a model without it can still translate. Read the average scores at the top, then each reviewer's feedback.
5. **Judging:** pick judge models the same way; the winner and the average judge scores appear when every judge has finished.
6. **If a reviewer or judge fails,** its card shows a plain error code and explanation. **Retry** runs the same model again; **Replace … with another model** runs a different one instead (reviewers until judging starts, judges until the editor is opened). Either way you see who will pay before anything starts.
7. **Edit the winning translation:** save versions, request AI suggestions, then **Finalize current version** and download TXT or DOCX.

New accounts are offered a seven-step guided tour once; **Help** (the **?** button in the sidebar) replays it and offers a shorter tour of the current page. Tours only highlight the interface: they never click, submit, upload, or start AI work.

The [user guide](docs/user-guide.md) covers every screen and lists the key terms in English, Vietnamese, and Japanese.

## Key design decisions

Most of the engineering is in making paid, slow, failure-prone AI calls behave like a dependable workflow. Each decision links to the code and the tests that exercise it.

- **The human checkpoint is a domain invariant.** Only the explicit finalize action finalizes a translation, and AI suggestions become versions only when a person applies them. Automatic workflows always end at "Ready for you to edit". — [`Finalizations::ApplyProposal`](app/services/finalizations/apply_proposal.rb), [`Pipelines::Advance`](app/services/pipelines/advance.rb); [automatic pipeline tests](test/system/automatic_pipelines_test.rb)
- **Paid AI work needs explicit, bounded approval.** An automatic launch stores the approved plan (models × document parts × retry limit) on the workflow run; for multi-part documents the plan's digest is rechecked at submit and the launch is refused if it changed. Actual spend is recorded per request and shown as known or partial; a later retry is a separate action with its own cost warning. — [`Pipelines::Start`](app/services/pipelines/start.rb); [submission tests](test/integration/translation_workspace_submission_test.rb)
- **Who pays is decided once and recorded.** New work is paid by the owner's own OpenRouter key or by platform-managed AI, as the owner selects; each run records its payer and exact key version, there is never a fallback between the two, and an explicit retry shows its payer and is refused if that payer changed after the page was shown. — [`Ai::BillingPolicy`](app/services/ai/billing_policy.rb); [retry payer tests](test/integration/workflow_recovery_authorization_test.rb)
- **Every launch is idempotent.** Each form carries a signed, single-use submission identity consumed under a row lock, so a double click or a replayed POST returns the existing translation instead of starting a second paid run. — [`TranslationWorkspace`](app/forms/translation_workspace.rb), [`ReplayIdentity`](app/services/replay_identity.rb); [replay tests](test/integration/replay_adversarial_test.rb)
- **AI jobs tolerate duplicates, late arrivals, and crashes.** Runs are committed before their jobs are enqueued; a job claims its run under a row lock by job ID and execution number, and a late result can only update the attempt that claimed it. A watchdog fails stuck work without calling a provider. — [`Ai::ExecutionClaim`](app/services/ai/execution_claim.rb), [`Ai::StaleExecutionReconciler`](app/services/ai/stale_execution_reconciler.rb); [job lineage tests](test/jobs/ai_job_lineage_test.rb)
- **Drafts live on the server, not in localStorage.** An encrypted server draft, a per-tab editor identity, and a monotonically increasing sequence number resolve lost responses and late duplicates deterministically, report another tab's newer draft as a conflict, and work across devices. — [`TranslationWorkspaceDrafts::Save`](app/services/translation_workspace_drafts/save.rb); [draft tests](test/integration/translation_workspace_draft_test.rb), [browser history tests](test/system/translation_workspace_history_test.rb)
- **Configuration is versioned, not edited in place.** Glossaries, methodologies, references, and workflow setups append revisions; a translation stores the exact revisions it used, and PostgreSQL triggers stop terminal history from being rewritten. — [database design](docs/architecture/database.md)
- **PostgreSQL coordinates all persistent workflow state.** Row and advisory locks, unique indexes, and `SKIP LOCKED` give idempotency and batched cleanup; Solid Queue keeps jobs in PostgreSQL too, so there is one stateful dependency to back up and reason about. — [reliability](docs/architecture/reliability.md); [multi-process concurrency tests](test/support/process_barrier.rb)
- **Untrusted input is contained.** DOCX goes through a bounded ZIP reader and DTD-free XML; PDFs are extracted in a resource-limited child process; model output is validated against JSON schemas before it is stored. — [`SourceImports::PdfExtractor`](app/services/source_imports/pdf_extractor.rb); [security](docs/security.md)

## Architecture

```mermaid
flowchart LR
  B["Browser<br/>Turbo + Stimulus<br/>+ React islands"] -->|HTTPS| CF["Cloudflare (TLS)<br/>+ Tunnel"]
  CF -->|HTTP, private network| KP["kamal-proxy"]
  KP --> PU["Puma · Rails 8.1<br/>controllers → forms/services"]
  PU --> PG[("PostgreSQL 17<br/>app data")]
  PU -->|enqueue after commit| Q[("Solid Queue<br/>(PostgreSQL)")]
  Q --> J["Jobs<br/>AI runs · workflow advance · cleanup"]
  J --> PG
  J -->|HTTPS| OR["OpenRouter"]
  PU --> FS[("Private file storage")]
  PU --> PDF["Resource-limited PDF worker"]
```

A single Rails monolith. Pages are server-rendered; a few interactive parts (AI settings, the guided tours, reference file uploads) are React/TypeScript islands mounted into that HTML, with Rails still validating and persisting everything. Controllers handle HTTP and ownership checks; a form object and namespaced services (`TranslationExperiments::`, `BlindReviews::`, `Judging::`, `Finalizations::`, `Pipelines::`, `SourceImports::`) own the workflows; jobs make every AI call through one provider client (`Ai::OpenRouterClient`). There is no Redis: in production Solid Queue, Solid Cache, and Solid Cable each use their own PostgreSQL database. Full topology, request path, and recurring jobs: [architecture overview](docs/architecture/overview.md).

## Translation workflow

```mermaid
flowchart TD
  S["Source + glossary + references + methodology"] --> T["Translation candidates<br/>1–6 models, independent"]
  T --> R["Blind review<br/>anonymous labels A, B, C…"]
  R --> J["Judging<br/>sees candidates + anonymous reviews"]
  J --> W["Winning translation"]
  W --> E["Human editor<br/>version 1 = winner"]
  E -. optional .-> P["AI suggestions<br/>never auto-applied"]
  P -. you apply or ignore .-> E
  E --> F(["You finalize → TXT / DOCX"])

  classDef human fill:#e0f2fe,stroke:#0369a1,color:#0c4a6e
  class E,F human
```

Judges receive the anonymous candidates and the anonymous review feedback. The winner is chosen by a Borda count: a candidate ranked *r* of *N* earns *N − r + 1* points from each judge; ties go to the higher average score. The average scores shown on the review and judging pages are a summary for people; they do not choose the winner. Details: [workflow and long documents](docs/architecture/workflow.md).

### Long documents, parts, and parallel work

**Why "8 / 8 parts".** A source longer than 4,000 characters (up to 100,000) is split losslessly into parts of at most about 4,000 characters, cut at paragraph and then sentence boundaries ([`LongDocuments::Segmenter`](app/services/long_documents/segmenter.rb)). A 29,000-character sermon becomes 8 parts. Each part is one provider request per model, and the parts are joined back in order afterwards. Splitting keeps every answer well inside the model's output limit: an answer cut off at that limit is still billed, so one huge request is both riskier and more expensive to repeat. If one part fails, only that part is retried. Review, judging, and suggestions follow the same parts. The guidance (glossary, methodology, up to five references) is sent with every part, so references add to each part's input.

**Why 32 job threads.** Every part of every model is enqueued at the same moment, after the launch commits ([`Ai::RunScheduler`](app/services/ai/run_scheduler.rb)). Solid Queue runs `JOB_THREADS` jobs at once, 32 by default in production and development ([`config/queue.yml`](config/queue.yml)). Three models × 8 parts = 24 requests then all start together, and a translation finishes in roughly the time of its slowest part, not the sum of all parts. With 5 threads the same work queued in five rounds. The counter on each card counts *finished* parts, so a fast model climbs 1/8, 2/8, … while a slower one can sit at 0/8 and then jump to 8/8, because its eight parts were running side by side the whole time.

Each thread holds a database connection while it waits for OpenRouter, so the connection pools grow with the thread count (`JOB_THREADS + RAILS_MAX_THREADS + 2` for the primary database, `+ 8` for the queue; [`config/database.yml`](config/database.yml)). At 32 threads one busy container needs about 88 PostgreSQL connections at peak, within the production server's 100. During a deploy the old and new containers briefly overlap, and two busy containers would exceed that limit, so deploy only while no AI work is running. Correctness does not depend on the thread count: every run is claimed under a row lock by job ID and execution number, so more threads only change speed.

## Data model

The UI says **Translation**; the code calls it `Experiment`, because each one is one source run against several competing candidates. Users only see the plain name.

```mermaid
erDiagram
  PROJECT ||--o{ DOCUMENT : contains
  DOCUMENT ||--o{ EXPERIMENT : "is translated in"
  EXPERIMENT ||--o{ TRANSLATION_RUN : candidates
  EXPERIMENT ||--o| REVIEW_ROUND : "blind review"
  REVIEW_ROUND ||--o| JUDGE_ROUND : "judged in"
  JUDGE_ROUND ||--o| FINAL_TRANSLATION : seeds
  FINAL_TRANSLATION ||--|{ FINAL_TRANSLATION_VERSION : versions
  EXPERIMENT ||--o| PIPELINE_RUN : "automatic workflow"
```

This is a simplified domain view. Diagrams of all 47 application tables with their keys, and the constraints that protect history, are in [database design](docs/architecture/database.md); per-table purpose and lifecycle are in the [data dictionary](docs/architecture/data-dictionary.md).

## Reliability

An AI run's lifecycle, the core of the reliability design:

```mermaid
stateDiagram-v2
  [*] --> pending: created in the launch transaction
  pending --> running: job claims run under row lock (job id + execution no.)
  running --> completed: output validated and stored on the claiming attempt
  running --> failed: provider error after bounded retries
  pending --> failed: watchdog — never started (no provider call)
  running --> failed: watchdog — claim went stale (no provider call)
  failed --> pending: owner clicks Retry (cost warning)
  completed --> [*]
```

| Problem | What the code does | Tested by |
| --- | --- | --- |
| Response lost after an autosave | Editor identity + increasing sequence; if this tab wrote last, equal or older sequences are acknowledged as replays | [draft tests](test/integration/translation_workspace_draft_test.rb) |
| Two tabs edit one draft | Optimistic `lock_version` → HTTP 409; the tab keeps its local text | [draft concurrency tests](test/services/translation_workspace_drafts/save_concurrency_test.rb) |
| Double-submitted launch | Signed single-use submission identity consumed under a row lock | [submission tests](test/integration/translation_workspace_submission_test.rb) |
| Duplicate or late job execution | Claim by job ID + execution number; late results update only their own attempt | [job lineage tests](test/jobs/ai_job_lineage_test.rb) |
| Many stuck automatic workflows | Bounded sweeper with a least-recently-reconciled cursor and `SKIP LOCKED` | [reliability doc](docs/architecture/reliability.md#4-automatic-workflows) |
| A reviewer or judge model cannot do the step (for example no provider with structured output) | Replace it within the round: the failed run keeps its status, error, and cost and points to its replacement; a database check allows this only for failed runs, a same-round foreign key keeps the replacement in the round, and averages, judging, and suggestions read only current runs | [replacement tests](test/services/replace_failed_runs_test.rb), [selection tests](test/integration/role_model_selection_test.rb) |
| Answer cut off at the output limit | Each part reserves up to 16k output tokens and limits model reasoning (low effort, or a token budget for model families that ignore effort); a cut-off answer is never stored as output but its billed usage is recorded as `incomplete_response` | [client tests](test/services/ai/open_router_client_test.rb) |
| OpenRouter 402 while many requests are in flight | The in-flight budget 402 is retried; an empty account and a spent key limit get their own error codes and explanations | [client tests](test/services/ai/open_router_client_test.rb) |

Autosave, idempotency, recovery, and cleanup fairness in detail: [reliability design](docs/architecture/reliability.md).

## Security

- Every owned record is loaded through the signed-in user's associations; other users' records look exactly like missing ones.
- Database-backed sessions that sign-out revokes, bcrypt passwords with email confirmation, and Google ID-token verification with single-use nonces.
- A strict nonce-based Content Security Policy, CSRF protection, per-route request-size limits, and rate limits on sign-in and uploads.
- Hostile-file handling (bounded DOCX parsing, a resource-limited PDF worker), encrypted drafts, and log filtering of text and identities.

Controls, limits, and residual risks: [security](docs/security.md).

## Testing and release quality

At the V1.1 release verification (October 2026): **1,209 Rails tests** (unit and integration) and **192 browser system tests** (headless Chrome), all passing in CI. These counts are taken from the dated [V1.1.0 release audit](docs/releases/v1.1.0-audit.md) and its CI runs; they are not from a new test run. For release `208a2b1` (2026-10-21) the full `bin/ci` gate passed locally on a throwaway PostgreSQL 17 database (**1,360 Rails tests**, **250 browser tests**) and GitHub CI passed on the deployed commit; see the [release record](docs/releases/2026-10-21-production-208a2b1.md).

- **Concurrency:** multi-process tests with barriers for upload budgets, launches, and reference creation; draft-save races.
- **Replay and recovery:** lost responses, Back/Forward navigation, multiple tabs, cancelled uploads, duplicate and stale jobs.
- **Database:** constraint and trigger tests, migration lock rehearsals, and a check that `structure.sql` matches PostgreSQL's own output.
- **Operations:** a local backup/restore drill, a production-boot contract test for the Kamal configuration, and a [breaker script](script/breakers/chunked_request_memory.rb) that loads the production Docker image with many large request bodies under a 768 MiB memory limit.
- **Languages:** a test that the EN/VI/JA locale files define the same keys.

`bin/ci` runs the full gate locally: RuboCop, whitespace, bundler-audit, importmap audit, Brakeman, Zeitwerk, a pending-migration check, and every test. GitHub Actions runs the same checks (except the local-only migration-status steps) as five jobs (`scan_ruby`, `scan_js`, `lint`, `test`, `system-test`), and [a test](test/config/ci_gate_test.rb) fails if `bin/ci` gains a step that CI does not run. Tests never call a real AI provider: provider clients are replaced by fakes, and Ruby `Net::HTTP` connections from tests are limited to loopback.

Every change is reviewed along the same dimensions:

| Dimension | Examples here |
| --- | --- |
| Security | ownership scoping, signed identities, input bounds, bounded file parsing |
| Data | PostgreSQL constraints and triggers, versioned history, restore drills |
| Flow | idempotent launches, replay-safe autosave, explicit retries |
| Environment | browser system tests, production-boot contract, preflight checks |
| Performance | bounded cleanup batches, upload and response size limits |
| Simplicity | one monolith, PostgreSQL-only infrastructure, focused services |

## Tech stack

| Layer | Choice |
| --- | --- |
| Backend | Ruby 3.4, Rails 8.1, Puma |
| Frontend | Hotwire (Turbo, Stimulus) via importmap; React 19 + TypeScript islands bundled by esbuild at image build (Node never ships in the production image); Tailwind CSS 4 |
| Database | PostgreSQL 17 with `structure.sql`, CHECK constraints, triggers, advisory locks |
| Jobs, cache, cable | Solid Queue, Solid Cache, Solid Cable (all PostgreSQL; no Redis) |
| AI gateway | OpenRouter behind `Ai::OpenRouterClient` (timeouts, 1 MiB response cap) |
| Files | Active Storage on a private volume; `rubyzip`, `pdf-reader` |
| Auth | `has_secure_password`, database sessions, Google Identity Services |
| Testing and scanning | Minitest, Capybara, Selenium; RuboCop, Brakeman, bundler-audit |
| Deployment | Docker, Kamal 2, kamal-proxy, Thruster |
| Backups | `bin/ops/backup` bundles (pg_dump + storage archive), OpenPGP encryption on the server, AWS S3 with versioning and Object Lock |

## Run it locally

**Prerequisites:** Ruby 3.4.10, Docker (for PostgreSQL 17), and Chrome or Chromium for system tests. Ubuntu and macOS both work.

```sh
git clone https://github.com/XKeviNguyen/three_heavens.git
cd three_heavens
cp .env.example .env        # then set the values below
bundle install
```

`.env` (read by `dotenv-rails` in development and test only, and ignored by git):

```sh
POSTGRES_USER=three_heavens
POSTGRES_PASSWORD=choose_a_local_password
POSTGRES_PORT=5433
OPENROUTER_API_KEY=          # optional; leave empty unless you intend to pay for real AI calls
GOOGLE_CLIENT_ID=            # optional; Google sign-in is hidden when empty
```

```sh
docker compose up -d postgres        # PostgreSQL 17 bound to 127.0.0.1 only
bin/rails db:prepare                 # creates and migrates the databases
bin/rails accounts:bootstrap_admin   # prompts for an admin email and password
bin/dev                              # Rails + Tailwind watcher on http://localhost:3000
```

In development, jobs run inside the web process (Rails' async adapter), so no separate worker is needed.

**Without an AI key** everything except the AI steps works: accounts, projects, uploads and text extraction, glossaries, references, methodologies, workflow setups, drafts, history, and the UI in all three languages. Running translations, reviews, judging, or suggestions needs a paid `OPENROUTER_API_KEY` and **AI access** turned on for the account under Admin → Users. Models are picked from the OpenRouter catalog right in the form; browsing the catalog is free. To see the full flow without paying, run `bin/capture-readme-screenshots`, which drives the real UI end to end with a fake AI client against the Rails test database. The run wipes and resets that database (the same one `bin/rails test` uses), so run it only in a disposable checkout connected to an isolated, throwaway database.

**Checks:**

```sh
bin/rails test            # unit and integration tests
bin/rails test:system     # browser tests (headless Chrome)
bin/ci                    # the full local gate, same checks as CI
```

> The Compose volume `three_heavens_postgres_data` (prefixed with the Compose project name) holds your local data; `docker compose down -v` deletes it.

## Project structure

```text
app/
  controllers/   HTTP boundary: authentication, ownership lookups, parameter shape
  forms/         TranslationWorkspace – validates and launches a translation
  models/        durable state and invariants (Experiment, TranslationRun, …)
  services/      workflows by domain: blind_reviews/, judging/, pipelines/,
                 source_imports/, translation_workspace_drafts/, ai/, operations/
  jobs/          AI runs, automatic-workflow advancement, reconciliation, cleanup
  javascript/    Stimulus controllers: autosave and navigation guard, uploads, model browser
  frontend/      React/TypeScript islands: AI settings, product tours, file inputs
  views/         server-rendered ERB with Turbo
config/          routes, CI gate (ci.rb), recurring jobs, Kamal deploy.yml, locales (en/vi/ja)
db/              migrations and structure.sql (PostgreSQL's own dump)
bin/ops/         backup, restore verification, preflight, post-deploy smoke test
docs/            architecture, security, operations, user guide
script/          README screenshot capture, production-image breaker, edge-proxy evaluation
test/            unit, integration, system, concurrency, migration, and config tests
```

## Deployment

The repository is configured for a single-host [Kamal](https://kamal-deploy.org/) deployment: a non-root Docker image reached only through a Cloudflare Tunnel (Cloudflare terminates TLS) and an unpublished kamal-proxy, Thruster in front of Puma, Solid Queue supervised inside Puma (32 job threads by default), four PostgreSQL databases (primary, queue, cache, cable), and a persistent private volume for uploaded files. Configuration comes only from environment variables and the operator's secret manager, and a contract test proves production refuses to boot without each required variable.

Backups are bundles of the primary database and the file volume, encrypted on the server and copied to AWS S3 as write-once, object-locked objects through an upload-only identity; a separate read-only identity downloads each copy back to verify it ([design](docs/operations/backup-and-restore.md#off-host-copies-on-aws-s3-production)).

Runbooks: [configuration](docs/operations/configuration.md) · [production deploy and rollback](docs/operations/production-deploy.md) · [backup and restore](docs/operations/backup-and-restore.md) · [disaster recovery](docs/operations/disaster-recovery.md).

## Status and limitations

- **In production.** Release `208a2b1` has run in production since 2026-10-21: 21 MiB uploads; reviewers, judges and AI suggestions chosen from the whole OpenRouter catalog (structured-output models only); replacing a failed reviewer or judge; average score panels; 32 job threads; the Admin **AI key** page; and the Codex review fixes. Its two migrations were applied, and a fresh encrypted backup was copied to AWS S3 beforehand. Details, evidence, and what is still open (the restore drill of that backup, the platform AI key): [release record](docs/releases/2026-10-21-production-208a2b1.md). Earlier releases: `a08d31e` (V1.1.0 with bring-your-own-key billing and guided tours, 2026-10-16) and `e4099f6` (2026-10-20). Uptime, traffic, and long-term operation with paid AI calls are not measured here.
- **Backups.** Encrypted on the server, then copied to AWS S3 with write-once, versioned, object-locked storage and separate upload and read-only identities ([design](docs/operations/backup-and-restore.md#off-host-copies-on-aws-s3-production)). Daily copies are designed but not installed; backups are taken before each release.
- **One AI provider:** all AI calls go through OpenRouter.
- **Retries can cost more than once:** application state is deduplicated, but after a network failure the provider may already have processed (and billed) a request that is then retried.
- **Text only:** no OCR for scanned PDFs, no legacy `.doc`, no layout-preserving export.
- **Single host:** horizontal scaling would need a dedicated job role and shared file storage.
- **Approximate token budgets:** context planning uses a conservative byte-based estimate, not each provider's tokenizer.
- **License: [MIT](LICENSE).** Copyright © 2026 Nguyen Thai Hoang. Three Heavens is open source: reuse, modification, distribution and commercial use are permitted under the MIT License, provided its copyright and permission notices are retained. Third-party components remain subject to their own licenses.

Deep dives: [architecture](docs/architecture/overview.md) · [workflow](docs/architecture/workflow.md) · [database](docs/architecture/database.md) · [data dictionary](docs/architecture/data-dictionary.md) · [reliability](docs/architecture/reliability.md) · [documents](docs/architecture/documents.md) · [security](docs/security.md) · [user guide](docs/user-guide.md) · [engineering case studies](docs/engineering-case-studies/README.md)
