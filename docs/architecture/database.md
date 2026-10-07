# Database design

PostgreSQL 17 is authoritative. The schema is kept as `db/structure.sql` (PostgreSQL's own `pg_dump` output) because the application relies on features a Ruby schema file cannot express: CHECK constraints, partial and expression indexes, and triggers that seal historical rows.

## UI names and model names

| Users see | Model / table |
| --- | --- |
| Project | `Project` / `projects` |
| Document (source) | `Document` / `documents` |
| Translation | `Experiment` / `experiments` |
| Translation candidate | `TranslationRun` |
| Blind review | `ReviewRound`, `ReviewRun`, `ReviewEvaluation` |
| Judging | `JudgeRound`, `JudgeRun`, `JudgeEvaluation` |
| Final translation, version | `FinalTranslation`, `FinalTranslationVersion` |
| AI suggestions | `FinalizationRound`, `FinalizationRun` |
| Automatic workflow | `PipelineRun`, `PipelineEvent` |
| Workflow setup | `WorkflowProfile`, `WorkflowProfileRevision`, `WorkflowProfileModelSelection` |
| Glossary | `Glossary`, `GlossaryRevision`, `GlossaryEntry` |
| Methodology | `MethodologyProfile`, `MethodologyProfileRevision` |
| Reference | `TranslationReference`, `TranslationReferenceRevision` |
| Uploaded source file (before launch) | `SourceImport` |
| Autosaved form | `TranslationWorkspaceDraft`, `TranslationWorkspaceDraftEditor` |
| Model | `LlmModel` |

## Core translation graph

```mermaid
erDiagram
  USER ||--o{ PROJECT : owns
  PROJECT ||--o{ DOCUMENT : contains
  DOCUMENT ||--o{ EXPERIMENT : "translated in"
  EXPERIMENT }o--o| GLOSSARY_REVISION : uses
  EXPERIMENT }o--o| METHODOLOGY_PROFILE_REVISION : uses
  EXPERIMENT ||--o{ EXPERIMENT_REFERENCE_REVISION : "snapshots"
  EXPERIMENT_REFERENCE_REVISION }o--|| TRANSLATION_REFERENCE_REVISION : references
  EXPERIMENT ||--o| DOCUMENT_EXECUTION_PLAN : "long-document plan"
  DOCUMENT_EXECUTION_PLAN ||--|{ EXPERIMENT_SEGMENT : parts

  EXPERIMENT ||--|{ TRANSLATION_RUN : candidates
  TRANSLATION_RUN }o--|| LLM_MODEL : "requested model"
  TRANSLATION_RUN ||--o{ TRANSLATION_SEGMENT_RUN : "per part"

  EXPERIMENT ||--o| REVIEW_ROUND : "blind review"
  REVIEW_ROUND ||--|{ REVIEW_RUN : reviewers
  REVIEW_RUN ||--|{ REVIEW_EVALUATION : "scores each candidate"
  REVIEW_EVALUATION }o--|| TRANSLATION_RUN : evaluates

  REVIEW_ROUND ||--o| JUDGE_ROUND : "judged in"
  JUDGE_ROUND ||--|{ JUDGE_RUN : judges
  JUDGE_RUN ||--|{ JUDGE_EVALUATION : "ranks each candidate"
  JUDGE_ROUND }o--o| TRANSLATION_RUN : winner

  JUDGE_ROUND ||--o| FINAL_TRANSLATION : seeds
  FINAL_TRANSLATION ||--|{ FINAL_TRANSLATION_VERSION : versions
  FINAL_TRANSLATION |o--o| FINAL_TRANSLATION_VERSION : "current version"
  FINAL_TRANSLATION ||--o{ FINALIZATION_ROUND : "AI suggestion rounds"
  FINALIZATION_ROUND }o--|| FINAL_TRANSLATION_VERSION : "exact base version"
  FINALIZATION_ROUND ||--|{ FINALIZATION_RUN : refiners
  FINAL_TRANSLATION_VERSION |o--o| FINALIZATION_RUN : "applied from"

  EXPERIMENT ||--o| PIPELINE_RUN : "automatic workflow"
  PIPELINE_RUN }o--|| WORKFLOW_PROFILE_REVISION : "runs exactly"
  PIPELINE_RUN ||--o{ PIPELINE_EVENT : timeline
```

`ReviewSegmentRun`, `JudgeSegmentRun`, and `FinalizationSegmentRun` mirror `TranslationSegmentRun` for long documents. Every provider call, including retries, is recorded as an `AiProviderAttempt` (polymorphic to the run it belongs to) with sanitized error codes, tokens, cost, and latency.

## Reusable guidance (versioned)

```mermaid
erDiagram
  USER ||--o{ GLOSSARY : owns
  GLOSSARY ||--|{ GLOSSARY_REVISION : "append-only"
  GLOSSARY_REVISION ||--|{ GLOSSARY_ENTRY : terms
  GLOSSARY }o--o| GLOSSARY_REVISION : current

  USER ||--o{ METHODOLOGY_PROFILE : owns
  METHODOLOGY_PROFILE ||--|{ METHODOLOGY_PROFILE_REVISION : "append-only"

  USER ||--o{ TRANSLATION_REFERENCE : owns
  TRANSLATION_REFERENCE ||--|{ TRANSLATION_REFERENCE_REVISION : "append-only"

  USER ||--o{ WORKFLOW_PROFILE : owns
  WORKFLOW_PROFILE ||--|{ WORKFLOW_PROFILE_REVISION : "append-only"
  WORKFLOW_PROFILE_REVISION ||--|{ WORKFLOW_PROFILE_MODEL_SELECTION : "models per role"
  WORKFLOW_PROFILE_MODEL_SELECTION }o--|| LLM_MODEL : "snapshot of"
```

Editing any of these creates a new revision with a SHA-256 configuration digest. Earlier revisions are never rewritten; archiving hides a library item from new translations but keeps its history. Workflow model selections also snapshot the model's display name, provider, and identifier, so history remains readable if a model is later deactivated.

## Accounts and request-coordination state

```mermaid
erDiagram
  USER ||--o{ SESSION : "signed-in browsers"
  USER ||--o{ FEDERATED_IDENTITY : "Google link"
  USER ||--o| UPLOAD_BUDGET : "upload rate window"
  USER ||--o{ SOURCE_IMPORT : "staged uploads"
  SOURCE_IMPORT |o--o| DOCUMENT : "consumed into"
  USER ||--o{ SOURCE_IMPORT_RETIREMENT : "cancelled upload keys"
  USER ||--o{ TRANSLATION_WORKSPACE_SUBMISSION : "launch identities"
  TRANSLATION_WORKSPACE_SUBMISSION |o--o| EXPERIMENT : "created"
  USER ||--o{ TRANSLATION_WORKSPACE_DRAFT : "autosaved forms"
  USER ||--o{ TRANSLATION_WORKSPACE_DRAFT_EDITOR : "per-tab sequence watermark"
  USER ||--o{ TRANSLATION_REFERENCE_CREATION : "reference create identities"
```

These tables make retries safe; their lifetimes and cleanup are described in [reliability](reliability.md) and [replay lifecycles](../replay_lifecycles.md). `ConsumedNonce` records Google sign-in nonces so each can be used only once.

## How history is protected

- **Foreign keys on every ordinary relationship.** The polymorphic `ai_provider_attempts` link is protected by a lineage trigger instead. Durable translation history (projects, documents, translations, AI results, final versions) is never deleted by the application; libraries are archived instead.
- **Triggers seal terminal records.** Completed runs, evaluations, revisions, plans, and segments cannot be updated or deleted in ways that would rewrite history. Tests bypass them only deliberately, mainly through the explicit `mutate_historical_fixture` helper.
- **CHECK constraints** bound text lengths, scores, token snapshots (for example `estimated input + reserved output + safety margin ≤ context window`), status/field combinations, and identity formats.
- **Unique and partial indexes** enforce one draft per user and context, one review round per translation, one consumption per upload, and similar invariants that Rails validations alone cannot guarantee under concurrency.
- **Migrations are rehearsed.** Recent migrations that touch populated tables use short lock timeouts, separate `VALIDATE CONSTRAINT` steps, and concurrent index builds, and tests exercise their lock behavior. `test/config/database_schema_format_test.rb` fails if any constraint or index in `structure.sql` is not spelled exactly as PostgreSQL deparses it.

## Working with the schema

`db/structure.sql` is generated by PostgreSQL 17's `pg_dump` when a migration runs; never edit it by hand. Regenerate it by running the migration against a database prepared from the committed file, with a PostgreSQL 17 `pg_dump` on the `PATH` (an older `pg_dump` refuses a PostgreSQL 17 server). Never modify a merged migration; add a new one.
