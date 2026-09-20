require "test_helper"
require_relative "../support/judging_test_helper"
require_relative "../support/final_translation_test_helper"
require_relative "../support/workflow_profile_test_helper"

class BackendIntegrityTest < ActiveSupport::TestCase
  include JudgingTestHelper
  include FinalTranslationTestHelper
  include WorkflowProfileTestHelper

  test "database rejects malformed provider attempt lineage and terminal mutation" do
    run = translation_runs(:one)
    connection = ApplicationRecord.connection

    assert_database_rejects do
      connection.execute(provider_attempt_insert_sql(run.id, stage: "review", attempt_number: 91))
    end

    connection.execute(provider_attempt_insert_sql(run.id, stage: "translation", attempt_number: 92))
    attempt = AiProviderAttempt.find_by!(provider_run: run, attempt_number: 92)
    assert_database_rejects do
      connection.execute("UPDATE ai_provider_attempts SET attempt_number = 999 WHERE id = #{attempt.id}")
    end
    assert_database_rejects do
      connection.execute("UPDATE ai_provider_attempts SET display_name_snapshot = 'rewritten' WHERE id = #{attempt.id}")
    end
    attempt.update!(status: :failed, completed_at: Time.current, error_code: "provider_failure")

    assert_database_rejects do
      connection.execute("UPDATE ai_provider_attempts SET display_name_snapshot = 'rewritten' WHERE id = #{attempt.id}")
    end
    assert_database_rejects do
      connection.execute(provider_attempt_insert_sql(9_999_999, stage: "translation", attempt_number: 93))
    end
    assert_database_rejects do
      connection.execute("DELETE FROM translation_runs WHERE id = #{run.id}")
    end
  end

  test "database preserves immutable workflow snapshots and monotonic revisions" do
    profile = create_workflow_profile
    revision = profile.current_revision
    connection = ApplicationRecord.connection

    assert_database_rejects do
      connection.execute("UPDATE workflow_profile_revisions SET name = 'rewritten' WHERE id = #{revision.id}")
    end

    skipped = profile.revisions.build(
      version: revision.version + 2,
      name: "Skipped revision",
      completion_mode: revision.completion_mode,
      configuration_digest: "a" * 64
    )
    assert_database_rejects do
      skipped.save!(validate: false)
    end
  end

  test "failed execution remains retryable while completed execution is sealed" do
    run = translation_runs(:one)
    run.update!(
      status: :failed,
      completed_at: Time.current,
      error_code: "provider_failure",
      error_message: "The provider failed safely."
    )
    run.update!(status: :pending, completed_at: nil, error_code: nil, error_message: nil)

    assert run.pending?

    run.update!(status: :completed, translated_text: "Terminal result", completed_at: Time.current)
    assert_database_rejects { run.update_column(:translated_text, "Rewritten result") }
  end

  test "database seals evaluation output after its run completes" do
    review_round = create_completed_review_round
    judge_round = review_round.create_judge_round!(status: :running)
    judge_run = judge_round.judge_runs.create!(judge_llm_model: llm_models(:openrouter_gpt))
    review_round.experiment.translation_runs.order(:id).each_with_index do |candidate, index|
      judge_run.judge_evaluations.create!(
        translation_run: candidate,
        anonymous_label: BlindReviews::CandidateLabel.for(index)
      )
    end
    complete_judge_run(judge_run)
    review_evaluation = review_round.review_runs.first.review_evaluations.first
    judge_evaluation = judge_run.judge_evaluations.first

    assert review_evaluation.review_run.completed?
    assert judge_evaluation.judge_run.completed?
    assert_database_rejects { review_evaluation.update_column(:strengths, "Rewritten review") }
    assert_database_rejects { judge_evaluation.update_column(:rationale, "Rewritten judgment") }
  end

  test "database rejects cross-owner automatic pipeline lineage" do
    profile = create_workflow_profile(user: users(:normal))
    experiment = experiments(:two)
    revision = profile.current_revision
    counts = WorkflowProfileModelSelection::ROLES.index_with { |role| revision.role_count(role) }
    pipeline = experiment.build_pipeline_run(
      workflow_profile_revision: revision,
      status: :running,
      current_stage: :translation,
      completion_mode: revision.completion_mode,
      translator_count: counts.fetch("translator"),
      reviewer_count: counts.fetch("reviewer"),
      judge_count: counts.fetch("judge"),
      finalizer_count: counts.fetch("finalizer"),
      authorized_initial_provider_run_count: counts.values.sum,
      configuration_digest: revision.configuration_digest,
      confirmed_at: Time.current,
      started_at: Time.current
    )

    assert_database_rejects do
      pipeline.save!(validate: false)
    end
  end

  test "database enforces monotonic final versions and judge winner lineage" do
    review_round = create_completed_review_round
    judge_round = review_round.create_judge_round!(status: :running)
    judge_run = judge_round.judge_runs.create!(judge_llm_model: llm_models(:openrouter_gpt))
    candidates = review_round.experiment.translation_runs.order(:id).to_a
    candidates.each_with_index do |candidate, index|
      judge_run.judge_evaluations.create!(
        translation_run: candidate,
        anonymous_label: BlindReviews::CandidateLabel.for(index)
      )
    end
    unevaluated_candidate = review_round.experiment.translation_runs.create!(
      llm_model: create_judge_model,
      status: :completed,
      translated_text: "Unevaluated translation",
      completed_at: Time.current
    )
    assert_database_rejects do
      ApplicationRecord.connection.execute(
        "UPDATE judge_runs SET winner_translation_run_id = #{unevaluated_candidate.id} WHERE id = #{judge_run.id}"
      )
    end
    assert_database_rejects do
      ApplicationRecord.connection.execute(
        "UPDATE judge_rounds SET winner_translation_run_id = #{unevaluated_candidate.id} WHERE id = #{judge_round.id}"
      )
    end
    judge_run.judge_evaluations.order(:anonymous_label).each_with_index do |evaluation, index|
      evaluation.update!(
        rank: index + 1,
        overall_score: 90 - index,
        rationale: "Ranked rationale",
        strengths: "Ranked strengths",
        risks: "Ranked risks"
      )
    end
    rank_two_candidate = judge_run.judge_evaluations.find_by!(rank: 2).translation_run
    assert_database_rejects do
      ApplicationRecord.connection.execute(
        "UPDATE judge_runs SET winner_translation_run_id = #{rank_two_candidate.id} WHERE id = #{judge_run.id}"
      )
    end

    complete_judge_run(judge_run)
    aggregate = Judging::Aggregate.call(judge_round)
    judge_round.update!(
      status: :completed,
      winner_translation_run_id: aggregate.winner_translation_run_id,
      aggregate_rankings: aggregate.rankings,
      aggregation_explanation: aggregate.explanation
    )

    final_translation = FinalTranslation.new(
      experiment: review_round.experiment,
      judge_round: judge_round,
      source_winner_translation_run: judge_round.winner_translation_run,
      status: :draft
    )
    final_translation.save!(validate: false)
    final_translation.versions.create!(version_number: 1, content: "Seed", origin: :seed)

    assert_database_rejects do
      final_translation.versions.create!(version_number: 3, content: "Skipped", origin: :manual)
    end

    foreign_review = ReviewRound.create!(experiment: experiments(:one))
    cross_winner = JudgeRound.new(
      review_round: foreign_review,
      status: :completed,
      winner_translation_run: translation_runs(:two)
    )
    assert_database_rejects { cross_winner.save!(validate: false) }
  end

  test "database blocks parent lineage changes after segment children exist" do
    project = users(:normal).projects.create!(
      name: "Segment parent integrity",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    source = "Đoạn dài。\n\n" * 1_500
    document = project.documents.create!(title: "Segmented source", source_text: source)
    experiment = document.experiments.create!(instruction_prompt: "Translate faithfully.")
    plan = LongDocuments::Planner.call(experiment)
    run = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
    run.translation_segment_runs.create!(
      experiment_segment: plan.segments.first,
      context_window_tokens_snapshot: 64_000,
      max_output_tokens_snapshot: 4_096,
      estimated_input_tokens: 1_000,
      reserved_output_tokens: 4_096,
      context_safety_margin_tokens: 1_024,
      budget_policy_version: Ai::ContextBudget::POLICY_VERSION
    )

    assert_database_rejects { run.update_column(:experiment_id, experiments(:two).id) }

    trigger_names = %w[
      prevent_translation_runs_parent_mutation
      prevent_review_runs_parent_mutation
      prevent_review_rounds_parent_mutation
      prevent_judge_runs_parent_mutation
      prevent_judge_rounds_parent_mutation
      prevent_finalization_runs_parent_mutation
      prevent_finalization_rounds_parent_mutation
      prevent_final_translations_parent_mutation
    ]
    quoted_names = trigger_names.map { |name| ApplicationRecord.connection.quote(name) }.join(", ")
    installed = ApplicationRecord.connection.select_value(<<~SQL.squish)
      SELECT COUNT(*) FROM pg_trigger
      WHERE tgname IN (#{quoted_names}) AND NOT tgisinternal
    SQL
    assert_equal trigger_names.size, installed
  end

  test "database rejects parent reassignment even before any child records exist" do
    owner = users(:normal)
    project = owner.projects.create!(
      name: "Parent lineage",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    other_project = owner.projects.create!(
      name: "Parent lineage sibling",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    foreign_project = users(:other).projects.create!(
      name: "Parent lineage foreign",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )

    document = project.documents.create!(title: "Parent lineage source", source_text: "Nguồn")
    other_document = other_project.documents.create!(title: "Sibling source", source_text: "Nguồn")
    foreign_document = foreign_project.documents.create!(title: "Foreign source", source_text: "Nguồn")
    bare_document = project.documents.create!(title: "Bare source", source_text: "Nguồn")
    experiment = document.experiments.create!(instruction_prompt: "Translate faithfully.")
    other_experiment = other_document.experiments.create!(instruction_prompt: "Translate faithfully.")
    foreign_experiment = foreign_document.experiments.create!(instruction_prompt: "Translate faithfully.")
    bare_experiment = bare_document.experiments.create!(instruction_prompt: "Translate faithfully.")

    run = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
    assert_historical_parent_rejected { run.update_column(:experiment_id, other_experiment.id) }
    assert_historical_parent_rejected { run.update_column(:experiment_id, foreign_experiment.id) }
    run.update!(status: :running, started_at: Time.current)
    assert run.reload.running?

    review_round = experiment.create_review_round!(status: :running)
    review_run = review_round.review_runs.create!(reviewer_llm_model: llm_models(:openrouter_claude))
    sibling_review_round = other_experiment.create_review_round!(status: :running)
    assert_historical_parent_rejected { review_run.update_column(:review_round_id, sibling_review_round.id) }
    assert_historical_parent_rejected { review_round.update_column(:experiment_id, bare_experiment.id) }

    judge_round = review_round.create_judge_round!(status: :running)
    judge_run = judge_round.judge_runs.create!(judge_llm_model: llm_models(:openrouter_gpt))
    sibling_judge_round = sibling_review_round.create_judge_round!(status: :running)
    bare_review_round = bare_experiment.create_review_round!(status: :running)
    assert_historical_parent_rejected { judge_run.update_column(:judge_round_id, sibling_judge_round.id) }
    assert_historical_parent_rejected { judge_round.update_column(:review_round_id, bare_review_round.id) }

    final_translation = create_final_translation_workspace
    sibling_final_translation = create_final_translation_workspace
    round = Finalizations::Start.call(
      final_translation: final_translation,
      finalizer_ids: [ create_finalizer.id ]
    )
    sibling_round = Finalizations::Start.call(
      final_translation: sibling_final_translation,
      finalizer_ids: [ create_finalizer.id ]
    )
    finalization_run = round.finalization_runs.first
    assert_historical_parent_rejected { finalization_run.update_column(:finalization_round_id, sibling_round.id) }
    assert_historical_parent_rejected do
      round.update_column(:final_translation_id, sibling_final_translation.id)
    end
    assert_historical_parent_rejected do
      final_translation.update_column(:experiment_id, sibling_final_translation.experiment_id)
    end
  end

  test "database rejects experiment glossary revision changes after creation" do
    owner = users(:normal)
    project = owner.projects.create!(
      name: "Glossary immutability",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    first_glossary = Glossaries::Create.call(
      user: owner,
      attributes: {
        "name" => "First glossary",
        "source_language" => "Vietnamese",
        "target_language" => "Japanese",
        "entries" => [ { "source_term" => "faith", "preferred_target_term" => "信仰" } ]
      }
    )
    second_glossary = Glossaries::Create.call(
      user: owner,
      attributes: {
        "name" => "Second glossary",
        "source_language" => "Vietnamese",
        "target_language" => "Japanese",
        "entries" => [ { "source_term" => "grace", "preferred_target_term" => "恵み" } ]
      }
    )
    document = project.documents.create!(title: "Glossary source", source_text: "Nguồn")
    experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully.",
      glossary_revision: first_glossary.current_revision
    )
    bare_experiment = document.experiments.create!(instruction_prompt: "Translate without a glossary.")

    assert_glossary_revision_rejected do
      experiment.update_column(:glossary_revision_id, second_glossary.current_revision.id)
    end
    assert_glossary_revision_rejected { experiment.update_column(:glossary_revision_id, nil) }
    assert_glossary_revision_rejected do
      bare_experiment.update_column(:glossary_revision_id, first_glossary.current_revision.id)
    end

    experiment.update!(instruction_prompt: "Updated with glossary.")
    bare_experiment.update!(instruction_prompt: "Updated without glossary.")
    assert_equal first_glossary.current_revision_id, experiment.reload.glossary_revision_id
    assert_nil bare_experiment.reload.glossary_revision_id
  end

  test "database blocks parent lineage changes after evaluation children exist" do
    project = users(:normal).projects.create!(
      name: "Evaluation parent integrity",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Evaluation parent source", source_text: "Nguồn")
    experiment = document.experiments.create!(instruction_prompt: "Translate faithfully.")
    candidate = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
    review_round = experiment.create_review_round!(status: :running)
    review_run = review_round.review_runs.create!(reviewer_llm_model: llm_models(:openrouter_claude))
    review_run.review_evaluations.create!(
      translation_run: candidate,
      anonymous_label: BlindReviews::CandidateLabel.for(0)
    )
    judge_round = review_round.create_judge_round!(status: :running)
    judge_run = judge_round.judge_runs.create!(judge_llm_model: llm_models(:openrouter_gpt))
    judge_run.judge_evaluations.create!(
      translation_run: candidate,
      anonymous_label: BlindReviews::CandidateLabel.for(1)
    )
    foreign_round = ReviewRound.create!(experiment: experiments(:two))
    foreign_judge_round = foreign_round.create_judge_round!(status: :running)

    assert_database_rejects { review_run.update_column(:review_round_id, foreign_round.id) }
    assert_database_rejects { review_round.update_column(:experiment_id, experiments(:two).id) }
    assert_database_rejects { candidate.update_column(:experiment_id, experiments(:two).id) }
    assert_database_rejects { judge_run.update_column(:judge_round_id, foreign_judge_round.id) }
    assert_database_rejects { judge_round.update_column(:review_round_id, foreign_round.id) }
  end

  test "database validates completion invariants before sealing records" do
    project = users(:normal).projects.create!(
      name: "Completion integrity",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Completion source", source_text: "Nguồn")
    experiment = document.experiments.create!(instruction_prompt: "Translate faithfully.")
    review_round = experiment.create_review_round!(status: :running)
    review_run = review_round.review_runs.create!(reviewer_llm_model: llm_models(:openrouter_claude))

    assert_database_rejects { review_round.update_column(:status, "completed") }
    assert_database_rejects { review_run.update_column(:status, "completed") }
    review_round.reload
    review_run.reload

    candidate = experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_gpt),
      status: :completed,
      translated_text: "Translated",
      completed_at: Time.current
    )
    review_run.review_evaluations.create!(
      translation_run: candidate,
      anonymous_label: BlindReviews::CandidateLabel.for(0),
      faithfulness_score: 9,
      naturalness_score: 9,
      terminology_score: 9,
      instruction_adherence_score: 9,
      overall_score: 9,
      strengths: "Strength",
      issues: "Issue",
      recommended_corrections: "Correction"
    )
    review_run.update!(status: :completed, completed_at: Time.current)
    review_round.update!(status: :completed)
    assert review_round.reload.completed?

    judge_round = review_round.create_judge_round!(status: :running)
    judge_run = judge_round.judge_runs.create!(judge_llm_model: create_judge_model)
    judge_run.judge_evaluations.create!(
      translation_run: candidate,
      anonymous_label: BlindReviews::CandidateLabel.for(0)
    )
    assert_database_rejects { judge_run.update_column(:status, "completed") }
    assert_database_rejects { judge_round.update_column(:status, "completed") }
  end

  test "database rejects directly inserted completed records" do
    assert_database_rejects do
      ReviewRound.new(experiment: experiments(:two), status: :completed).save!(validate: false)
    end
  end

  test "database requires a proposal before sealing a finalization run" do
    final_translation = create_final_translation_workspace
    round = Finalizations::Start.call(
      final_translation: final_translation,
      finalizer_ids: [ create_finalizer.id ]
    )
    run = round.finalization_runs.first

    assert_database_rejects { run.update_column(:status, "completed") }
    run.reload

    complete_finalization_run(run)
    assert run.reload.completed?
  end

  private

  def assert_database_rejects(&block)
    assert_raises ActiveRecord::StatementInvalid do
      ApplicationRecord.transaction(requires_new: true, &block)
    end
  end

  def assert_historical_parent_rejected(&block)
    error = assert_database_rejects(&block)
    assert_includes error.message, "Historical parent lineage cannot change after creation"
    error
  end

  def assert_glossary_revision_rejected(&block)
    error = assert_database_rejects(&block)
    assert_includes error.message, "Experiment glossary revision cannot change after creation"
    error
  end

  def provider_attempt_insert_sql(run_id, stage:, attempt_number:)
    <<~SQL.squish
      INSERT INTO ai_provider_attempts (
        provider_run_type, provider_run_id, attempt_number, stage, status,
        gateway_snapshot, provider_snapshot, model_identifier_snapshot,
        display_name_snapshot, started_at, created_at, updated_at
      ) VALUES (
        'TranslationRun', #{Integer(run_id)}, #{Integer(attempt_number)},
        #{ApplicationRecord.connection.quote(stage)}, 'running', 'openrouter',
        'test', 'test/model', 'Test model', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
      )
    SQL
  end
end
