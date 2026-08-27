require "test_helper"
require_relative "../support/final_translation_test_helper"

class FinalTranslationModelsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @final_translation = create_final_translation_workspace
  end

  test "persists the workspace graph and immutable seed version" do
    version = @final_translation.current_version

    assert_equal @final_translation.experiment, @final_translation.judge_round.experiment
    assert_equal @final_translation.judge_round.winner_translation_run,
                 @final_translation.source_winner_translation_run
    assert_equal @final_translation, version.final_translation
    assert version.seed?
    assert_equal 1, version.version_number
    assert_not version.update(content: "Mutated history")
    assert_equal @final_translation.source_winner_translation_run.translated_text,
                 version.reload.content
  end

  test "validates workspace and version relationship invariants" do
    other = create_final_translation_workspace
    @final_translation.current_version = other.current_version
    assert_not @final_translation.valid?
    assert_includes @final_translation.errors[:current_version], "must belong to this final translation"

    @final_translation.reload
    @final_translation.source_winner_translation_run = other.source_winner_translation_run
    assert_not @final_translation.valid?
    assert_includes @final_translation.errors[:source_winner_translation_run],
                    "must belong to the final translation experiment"
  end

  test "enforces version number origin content and database constraints" do
    duplicate = @final_translation.versions.build(
      version_number: 1,
      content: "Duplicate",
      origin: :manual
    )
    assert_not duplicate.valid?

    invalid_origin = @final_translation.versions.build(
      version_number: 2,
      content: "Text",
      origin: "unknown"
    )
    assert_not invalid_origin.valid?

    assert_raises ActiveRecord::StatementInvalid do
      @final_translation.current_version.update_column(:version_number, 0)
    end
    assert_raises ActiveRecord::StatementInvalid do
      @final_translation.update_column(:status, "unknown")
    end
  end

  test "round base and applied proposal must belong to the same workspace" do
    finalizer = create_finalizer
    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ finalizer.id ]
    )
    clear_enqueued_jobs
    run = complete_finalization_run(round.finalization_runs.first)
    other = create_final_translation_workspace

    foreign_round = other.finalization_rounds.build(
      base_version: @final_translation.current_version,
      selection_key: "a" * 64
    )
    assert_not foreign_round.valid?

    foreign_version = other.versions.build(
      version_number: 2,
      content: "Proposal",
      origin: :ai_applied,
      source_finalization_run: run
    )
    assert_not foreign_version.valid?
  end

  test "restricts deletion of final translation history" do
    finalizer = create_finalizer
    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ finalizer.id ]
    )
    clear_enqueued_jobs

    assert_not @final_translation.destroy
    assert_not @final_translation.current_version.destroy
    assert_not @final_translation.source_winner_translation_run.destroy
    assert_not round.destroy
    assert_not round.finalization_runs.first.destroy
    assert_not finalizer.destroy
  end

  test "database enforces one workspace version uniqueness run uniqueness and one active round" do
    assert_raises ActiveRecord::RecordNotUnique do
      FinalTranslation.transaction(requires_new: true) do
        FinalTranslation.insert_all!([ {
          experiment_id: @final_translation.experiment_id,
          judge_round_id: @final_translation.judge_round_id,
          source_winner_translation_run_id: @final_translation.source_winner_translation_run_id,
          current_version_id: @final_translation.current_version_id,
          status: "draft",
          lock_version: 0,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    finalizer = create_finalizer
    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ finalizer.id ]
    )
    clear_enqueued_jobs
    assert_raises ActiveRecord::RecordNotUnique do
      FinalizationRun.transaction(requires_new: true) do
        round.finalization_runs.insert_all!([ {
          finalizer_llm_model_id: finalizer.id,
          status: "pending",
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end
    assert_raises ActiveRecord::RecordNotUnique do
      FinalizationRound.transaction(requires_new: true) do
        @final_translation.finalization_rounds.insert_all!([ {
          base_final_translation_version_id: @final_translation.current_version_id,
          status: "running",
          selection_key: "b" * 64,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end
  end

  test "finalizer model identifier is immutable after use and history survives deactivation" do
    finalizer = create_finalizer
    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ finalizer.id ]
    )
    clear_enqueued_jobs
    run = complete_finalization_run(round.finalization_runs.first)

    finalizer.update!(active: false)
    finalizer.model_identifier = "finalizer/changed"
    assert_not finalizer.valid?
    assert_equal run, finalizer.finalization_runs.first
    assert_equal "Polished final translation", run.reload.proposed_translation
    assert_not_includes LlmModel.active_openrouter, finalizer
  end

  test "PostgreSQL composite foreign keys reject foreign current base and seed relationships" do
    other = create_final_translation_workspace

    assert_raises ActiveRecord::StatementInvalid do
      FinalTranslation.transaction(requires_new: true) do
        @final_translation.update_columns(current_version_id: other.current_version_id)
      end
    end
    @final_translation.reload
    assert_raises ActiveRecord::StatementInvalid do
      FinalTranslation.transaction(requires_new: true) do
        @final_translation.update_columns(
          source_winner_translation_run_id: other.source_winner_translation_run_id
        )
      end
    end

    assert_raises ActiveRecord::StatementInvalid do
      FinalizationRound.transaction(requires_new: true) do
        @final_translation.finalization_rounds.insert_all!([ {
          base_final_translation_version_id: other.current_version_id,
          status: "running",
          selection_key: "c" * 64,
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    foreign_key_names = ActiveRecord::Base.connection.foreign_keys(:final_translations).map(&:name)
    assert_includes foreign_key_names, "fk_final_translations_current_owned_version"
    assert_includes foreign_key_names, "fk_final_translations_winner_in_experiment"
    assert_includes foreign_key_names, "fk_final_translations_official_judge_winner"
  end
end
