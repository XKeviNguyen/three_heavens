require "test_helper"
require_relative "../../support/final_translation_test_helper"

class Ai::UsageLimitsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  test "source and instruction accept exact limits and reject one character over" do
    exact = workspace(
      source_text: "s" * Ai::UsageLimits::MAX_SOURCE_CHARACTERS,
      instruction_prompt: "i" * Ai::UsageLimits::MAX_INSTRUCTION_CHARACTERS
    )
    over_source = workspace(source_text: "s" * (Ai::UsageLimits::MAX_SOURCE_CHARACTERS + 1))
    over_instruction = workspace(
      instruction_prompt: "i" * (Ai::UsageLimits::MAX_INSTRUCTION_CHARACTERS + 1)
    )

    assert exact.valid?
    assert_not over_source.valid?
    assert over_source.errors[:source_text].any?
    assert_not over_instruction.valid?
    assert over_instruction.errors[:instruction_prompt].any?
  end

  test "translation model limit rejects over-limit duplicate malformed and mixed selections before work" do
    models = usage_models(Ai::UsageLimits::MAX_TRANSLATION_MODELS + 1)
    assert workspace(model_ids: models.first(Ai::UsageLimits::MAX_TRANSLATION_MODELS).map(&:id)).valid?

    invalid_selections = [
      models.map(&:id),
      [ models.first.id, models.first.id ],
      models.first.id.to_s,
      [ models.first.id, "bad-id" ],
      [ models.first.id, 99_999_999 ]
    ]
    invalid_selections.each do |selection|
      invalid = workspace(model_ids: selection)

      assert_no_difference [ -> { Project.count }, -> { TranslationRun.count } ] do
        assert_no_enqueued_jobs only: TranslationRunJob do
          assert_not invalid.submit
        end
      end
      assert invalid.errors[:model_ids].any?
    end
  end

  test "reviewer limit accepts exactly five and rejects larger or malformed lists before jobs" do
    reviewers = usage_models(Ai::UsageLimits::MAX_REVIEWERS + 1)
    exact_experiment = completed_translation_experiment

    assert_enqueued_jobs Ai::UsageLimits::MAX_REVIEWERS, only: ReviewRunJob do
      round = BlindReviews::Start.call(
        experiment: exact_experiment,
        reviewer_ids: reviewers.first(Ai::UsageLimits::MAX_REVIEWERS).map(&:id)
      )
      assert_equal Ai::UsageLimits::MAX_REVIEWERS, round.review_runs.count
    end
    clear_enqueued_jobs

    [ reviewers.map(&:id), reviewers.first.id.to_s, [ reviewers.first.id, reviewers.first.id ] ].each do |ids|
      experiment = completed_translation_experiment
      assert_no_difference [ -> { ReviewRound.count }, -> { ReviewRun.count } ] do
        assert_no_enqueued_jobs only: ReviewRunJob do
          assert_raises BlindReviews::Start::InvalidReviewerSelectionError do
            BlindReviews::Start.call(experiment: experiment, reviewer_ids: ids)
          end
        end
      end
    end
  end

  test "judge limit accepts exactly five and rejects a sixth before jobs" do
    judges = usage_models(Ai::UsageLimits::MAX_JUDGES + 1)
    exact_review = create_completed_review_round

    assert_enqueued_jobs Ai::UsageLimits::MAX_JUDGES, only: JudgeRunJob do
      round = Judging::Start.call(
        review_round: exact_review,
        judge_ids: judges.first(Ai::UsageLimits::MAX_JUDGES).map(&:id)
      )
      assert_equal Ai::UsageLimits::MAX_JUDGES, round.judge_runs.count
    end
    clear_enqueued_jobs

    over_review = create_completed_review_round
    assert_no_difference [ -> { JudgeRound.count }, -> { JudgeRun.count } ] do
      assert_no_enqueued_jobs only: JudgeRunJob do
        assert_raises Judging::Start::InvalidJudgeSelectionError do
          Judging::Start.call(review_round: over_review, judge_ids: judges.map(&:id))
        end
      end
    end
  end

  test "finalizer limit accepts exactly five and rejects a sixth before jobs" do
    finalizers = usage_models(Ai::UsageLimits::MAX_FINALIZERS + 1)
    exact_workspace = create_final_translation_workspace

    assert_enqueued_jobs Ai::UsageLimits::MAX_FINALIZERS, only: FinalizationRunJob do
      round = Finalizations::Start.call(
        final_translation: exact_workspace,
        finalizer_ids: finalizers.first(Ai::UsageLimits::MAX_FINALIZERS).map(&:id)
      )
      assert_equal Ai::UsageLimits::MAX_FINALIZERS, round.finalization_runs.count
    end
    clear_enqueued_jobs

    over_workspace = create_final_translation_workspace
    assert_no_difference [ -> { FinalizationRound.count }, -> { FinalizationRun.count } ] do
      assert_no_enqueued_jobs only: FinalizationRunJob do
        assert_raises FinalTranslations::InvalidSelectionError do
          Finalizations::Start.call(
            final_translation: over_workspace,
            finalizer_ids: finalizers.map(&:id)
          )
        end
      end
    end
  end

  private

  def workspace(overrides = {})
    TranslationWorkspace.new(
      {
        user: users(:normal),
        project_name: "Usage limit project",
        source_language: "Vietnamese",
        target_language: "English",
        document_title: "Usage limit document",
        source_text: "Source text",
        experiment_name: "Usage limit experiment",
        instruction_prompt: "Translate faithfully.",
        model_ids: [ llm_models(:openrouter_claude).id ]
      }.merge(overrides)
    )
  end

  def usage_models(count)
    Array.new(count) do
      suffix = SecureRandom.hex(6)
      LlmModel.create!(
        gateway: "openrouter",
        provider: "usage-provider",
        model_identifier: "usage/#{suffix}",
        display_name: "Usage model #{suffix}"
      )
    end
  end

  def completed_translation_experiment
    suffix = SecureRandom.hex(6)
    project = Project.create!(
      user: users(:normal),
      name: "Review limits #{suffix}",
      source_language: "Vietnamese",
      target_language: "English"
    )
    experiment = project.documents.create!(
      title: "Limits source",
      source_text: "Limits source text"
    ).experiments.create!(
      instruction_prompt: "Translate faithfully.",
      status: :completed
    )
    [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ].each do |model|
      experiment.translation_runs.create!(
        llm_model: model,
        status: :completed,
        translated_text: "Candidate #{model.id}"
      )
    end
    experiment
  end
end
