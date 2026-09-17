require "test_helper"
require_relative "../support/judging_test_helper"
require_relative "../support/workflow_profile_test_helper"

class BackendIntegrityTest < ActiveSupport::TestCase
  include JudgingTestHelper
  include WorkflowProfileTestHelper

  test "database rejects malformed provider attempt lineage and terminal mutation" do
    run = translation_runs(:one)
    connection = ApplicationRecord.connection

    assert_database_rejects do
      connection.execute(provider_attempt_insert_sql(run.id, stage: "review", attempt_number: 91))
    end

    connection.execute(provider_attempt_insert_sql(run.id, stage: "translation", attempt_number: 92))
    attempt = AiProviderAttempt.find_by!(provider_run: run, attempt_number: 92)
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
    review_round = ReviewRound.create!(experiment: experiments(:two))
    pending_candidate = experiments(:two).translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :pending
    )
    assert pending_candidate.pending?
    assert_database_rejects do
      ApplicationRecord.connection.execute(<<~SQL.squish)
        INSERT INTO judge_rounds (
          review_round_id, winner_translation_run_id, status,
          aggregate_rankings, created_at, updated_at
        ) VALUES (
          #{review_round.id}, #{pending_candidate.id}, 'completed',
          '[]', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        )
      SQL
    end

    judge_round = JudgeRound.new(
      review_round: review_round,
      status: :completed,
      winner_translation_run: translation_runs(:two)
    )
    judge_round.save!(validate: false)
    final_translation = FinalTranslation.new(
      experiment: experiments(:two),
      judge_round: judge_round,
      source_winner_translation_run: translation_runs(:two),
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

  private

  def assert_database_rejects(&block)
    assert_raises ActiveRecord::StatementInvalid do
      ApplicationRecord.transaction(requires_new: true, &block)
    end
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
