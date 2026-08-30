require "test_helper"
require_relative "../../support/workflow_profile_test_helper"

class Pipelines::StartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include WorkflowProfileTestHelper

  setup do
    project = users(:normal).projects.create!(name: "Automatic launch", source_language: "Vietnamese", target_language: "Japanese")
    document = project.documents.create!(title: "Source", source_text: "Source")
    @experiment = document.experiments.create!(instruction_prompt: "Translate faithfully.")
    @profile = create_workflow_profile
  end

  test "persists exact authorization and starts existing translation service once" do
    assert_difference -> { PipelineRun.count }, 1 do
      assert_difference -> { TranslationRun.count }, 2 do
        assert_enqueued_jobs 2, only: TranslationRunJob do
          @pipeline = Pipelines::Start.call(
            experiment: @experiment,
            user: users(:normal),
            workflow_profile_revision: @profile.current_revision,
            confirmation: "1"
          )
        end
      end
    end

    assert_equal 4, @pipeline.authorized_initial_provider_run_count
    assert_equal 2, @pipeline.translator_count
    assert_equal @profile.configuration_digest, @pipeline.configuration_digest
    assert_equal %w[pipeline_started translation_started], @pipeline.events.pluck(:event_type)
  end

  test "snapshots segmented provider-work multiplication before scheduling" do
    source = "Long paragraph。\n\n" * 500
    @experiment.document.update!(source_text: source)
    @profile.current_revision.model_selections.each do |selection|
      selection.llm_model.update!(context_window_tokens: 64_000, max_output_tokens: 4_096)
    end

    expected_translation_jobs = LongDocuments::Segmenter.call(source).size * 2
    assert_enqueued_jobs expected_translation_jobs, only: TranslationSegmentRunJob do
      @pipeline = start_pipeline
    end

    segment_count = @experiment.document_execution_plan.segment_count
    expected = @profile.current_revision.model_selections.count * segment_count
    assert_equal expected, @pipeline.authorized_initial_provider_run_count
    assert_equal expected, @pipeline.provider_work_plan.fetch("authorized_initial_provider_request_slots")
    assert_equal segment_count, @pipeline.provider_work_plan.fetch("segment_count")
    assert_equal 2 * segment_count,
                 @pipeline.provider_work_plan.dig("roles", "translator", "provider_request_slots")
    assert_equal 2 * segment_count, @experiment.translation_runs.sum { |run| run.translation_segment_runs.count }
  end

  test "segmented launches require the exact provider-work plan digest" do
    source = "Long paragraph。\n\n" * 500
    @experiment.document.update!(source_text: source)
    @profile.current_revision.model_selections.each do |selection|
      selection.llm_model.update!(context_window_tokens: 64_000, max_output_tokens: 4_096)
    end

    assert_no_difference [ -> { PipelineRun.count }, -> { TranslationRun.count }, -> { DocumentExecutionPlan.count } ] do
      assert_no_enqueued_jobs only: TranslationSegmentRunJob do
        assert_raises(Pipelines::Start::ConfirmationRequiredError) do
          start_pipeline(expected_provider_work_plan_digest: "0" * 64)
        end
      end
    end
  end

  test "confirmation inactive stale cross-owner and changed routing fail closed" do
    assert_raises Pipelines::Start::ConfirmationRequiredError do
      start_pipeline(confirmation: "0")
    end
    @profile.update!(active: false)
    assert_raises Pipelines::Start::InactiveProfileError do
      start_pipeline
    end
    @profile.update!(active: true)

    old_revision = @profile.current_revision
    WorkflowProfiles::Revise.call(
      workflow_profile: @profile,
      expected_version: 1,
      attributes: workflow_profile_attributes(name: "Current")
    )
    assert_raises Pipelines::Start::StaleRevisionError do
      start_pipeline(revision: old_revision)
    end
    assert_raises ActiveRecord::RecordNotFound do
      Pipelines::Start.call(
        experiment: @experiment,
        user: users(:other),
        workflow_profile_revision: @profile.current_revision,
        confirmation: "1"
      )
    end

    mutable_model = LlmModel.create!(
      gateway: "openrouter",
      provider: "mutable",
      model_identifier: "mutable/before-profile-launch",
      display_name: "Mutable before launch",
      active: true
    )
    WorkflowProfiles::Revise.call(
      workflow_profile: @profile,
      expected_version: 2,
      attributes: workflow_profile_attributes(name: "Mutable routing").merge(
        translator_ids: [ mutable_model.id, llm_models(:openrouter_claude).id ]
      )
    )
    mutable_model.update!(model_identifier: "mutable/after-profile-launch")
    assert_raises Pipelines::Start::ConfigurationUnavailableError do
      start_pipeline
    end
    assert_equal 0, PipelineRun.count
    assert_equal 0, @experiment.translation_runs.count
  end

  test "experiment profile and supplied user ownership must all match without admin bypass" do
    other_project = users(:other).projects.create!(
      name: "Other private experiment",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    other_experiment = other_project.documents.create!(title: "Private", source_text: "Source").experiments.create!(
      instruction_prompt: "Translate."
    )

    assert_no_difference [ -> { PipelineRun.count }, -> { TranslationRun.count } ] do
      assert_no_enqueued_jobs only: TranslationRunJob do
        assert_raises ActiveRecord::RecordNotFound do
          Pipelines::Start.call(
            experiment: other_experiment,
            user: users(:normal),
            workflow_profile_revision: @profile.current_revision,
            confirmation: "1"
          )
        end
      end
    end

    admin_profile = create_workflow_profile(user: users(:admin))
    assert_no_difference [ -> { PipelineRun.count }, -> { TranslationRun.count } ] do
      assert_no_enqueued_jobs only: TranslationRunJob do
        assert_raises ActiveRecord::RecordNotFound do
          Pipelines::Start.call(
            experiment: other_experiment,
            user: users(:admin),
            workflow_profile_revision: admin_profile.current_revision,
            confirmation: "1"
          )
        end
      end
    end
  end

  private

  def start_pipeline(confirmation: "1", revision: @profile.current_revision,
                     expected_provider_work_plan_digest: segmented_plan_digest(revision))
    Pipelines::Start.call(
      experiment: @experiment,
      user: users(:normal),
      workflow_profile_revision: revision,
      confirmation: confirmation,
      expected_provider_work_plan_digest: expected_provider_work_plan_digest
    )
  end

  def segmented_plan_digest(revision)
    source = @experiment.document.source_text
    return if source.length <= LongDocuments::Segmenter::TARGET_CHARACTERS

    role_models = WorkflowProfileModelSelection::ROLES.to_h do |role|
      [ role, revision.selections_for(role).map(&:llm_model) ]
    end
    preview = LongDocuments::ProviderWorkPlan.call(
      execution_plan: LongDocuments::ProviderWorkPlan::Preview.new(
        segment_count: LongDocuments::Segmenter.call(source).size
      ),
      role_models: role_models,
      source_character_count: source.length
    )
    LongDocuments::ProviderWorkPlan.digest(preview)
  end
end
