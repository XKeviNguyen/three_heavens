require "test_helper"
require_relative "../support/final_translation_test_helper"

class OwnershipAuthorizationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @current_test_user = users(:normal)
    @own_final_translation = create_final_translation_workspace

    @current_test_user = users(:other)
    @foreign_final_translation = create_final_translation_workspace
    foreign_finalizer = create_finalizer
    foreign_round = Finalizations::Start.call(
      final_translation: @foreign_final_translation,
      finalizer_ids: [ foreign_finalizer.id ]
    )
    @foreign_finalization_run = complete_finalization_run(
      foreign_round.finalization_runs.first,
      proposal: "Another user's private proposal"
    )
    clear_enqueued_jobs

    @current_test_user = users(:normal)
    sign_in_as @current_test_user
  end

  test "owner can reach every stage of their workflow" do
    experiment = @own_final_translation.experiment
    review_round = experiment.review_round
    judge_round = review_round.judge_round

    [
      experiment_path(experiment),
      review_round_path(review_round),
      judge_round_path(judge_round),
      final_translation_path(@own_final_translation),
      download_final_translation_path(@own_final_translation, format: :txt)
    ].each do |path|
      get path
      assert_response :success
    end
  end

  test "foreign workflow pages and download return not found" do
    experiment = @foreign_final_translation.experiment
    review_round = experiment.review_round
    judge_round = review_round.judge_round

    [
      experiment_path(experiment),
      review_round_path(review_round),
      judge_round_path(judge_round),
      final_translation_path(@foreign_final_translation),
      download_final_translation_path(@foreign_final_translation, format: :docx)
    ].each do |path|
      get path
      assert_response :not_found
    end
  end

  test "foreign parent IDs cannot start nested workflow operations" do
    assert_no_difference [ -> { ReviewRound.count }, -> { JudgeRound.count }, -> { FinalTranslation.count } ] do
      post experiment_review_rounds_path(@foreign_final_translation.experiment),
           params: { review_round: { reviewer_ids: [ llm_models(:openrouter_claude).id ] } }
      assert_response :not_found

      post review_round_judge_rounds_path(@foreign_final_translation.judge_round.review_round),
           params: { judge_round: { judge_ids: [ llm_models(:openrouter_claude).id ] } }
      assert_response :not_found

      post judge_round_final_translation_path(@foreign_final_translation.judge_round)
      assert_response :not_found
    end
  end

  test "foreign final translation mutations all return not found and create no work" do
    current = @foreign_final_translation.current_version

    assert_no_difference [ -> { FinalTranslationVersion.count }, -> { FinalizationRound.count } ] do
      patch save_revision_final_translation_path(@foreign_final_translation), params: {
        final_translation: {
          content: "Unauthorized edit",
          expected_version_number: current.version_number
        }
      }
      assert_response :not_found

      post restore_revision_final_translation_path(@foreign_final_translation), params: {
        restore: {
          version_id: current.id,
          expected_version_number: current.version_number
        }
      }
      assert_response :not_found

      post refine_final_translation_path(@foreign_final_translation), params: {
        refinement: { finalizer_ids: [ llm_models(:openrouter_claude).id ] }
      }
      assert_response :not_found

      post apply_proposal_final_translation_path(@foreign_final_translation), params: {
        proposal: { finalization_run_id: @foreign_finalization_run.id }
      }
      assert_response :not_found

      patch finalize_final_translation_path(@foreign_final_translation)
      assert_response :not_found

      patch reopen_final_translation_path(@foreign_final_translation)
      assert_response :not_found
    end
    assert_no_enqueued_jobs
  end

  test "foreign nested revision and proposal IDs cannot be applied to an owned workspace" do
    own_current = @own_final_translation.current_version
    foreign_version = @foreign_final_translation.current_version

    assert_no_difference -> { FinalTranslationVersion.count } do
      post restore_revision_final_translation_path(@own_final_translation), params: {
        restore: {
          version_id: foreign_version.id,
          expected_version_number: own_current.version_number
        }
      }
      assert_response :unprocessable_content

      post apply_proposal_final_translation_path(@own_final_translation), params: {
        proposal: { finalization_run_id: @foreign_finalization_run.id }
      }
      assert_response :unprocessable_content
    end
  end
end
