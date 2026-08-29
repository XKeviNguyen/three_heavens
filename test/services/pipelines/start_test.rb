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

  def start_pipeline(confirmation: "1", revision: @profile.current_revision)
    Pipelines::Start.call(
      experiment: @experiment,
      user: users(:normal),
      workflow_profile_revision: revision,
      confirmation: confirmation
    )
  end
end
