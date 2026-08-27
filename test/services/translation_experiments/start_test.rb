require "test_helper"

class TranslationExperiments::StartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Vietnamese to Japanese Sermons",
      source_language: "vi",
      target_language: "ja"
    )
    document = project.documents.create!(
      title: "The Sabbath",
      source_text: "Source theological text"
    )
    @experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully into Japanese."
    )
  end

  test "creates and enqueues one run per selected active model" do
    models = [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ]

    assert_difference -> { TranslationRun.count }, 2 do
      assert_enqueued_jobs 2, only: TranslationRunJob do
        runs = TranslationExperiments::Start.call(
          experiment: @experiment,
          llm_models: models
        )

        assert_equal models.to_set, runs.map(&:llm_model).to_set
        assert runs.all?(&:pending?)
      end
    end

    assert @experiment.reload.running?
  end

  test "does not duplicate or re-enqueue existing runs" do
    model = llm_models(:openrouter_claude)
    existing_runs = TranslationExperiments::Start.call(
      experiment: @experiment,
      llm_models: [ model ]
    )
    clear_enqueued_jobs

    assert_no_difference -> { TranslationRun.count } do
      assert_no_enqueued_jobs only: TranslationRunJob do
        repeated_runs = TranslationExperiments::Start.call(
          experiment: @experiment,
          llm_models: [ model ]
        )

        assert_equal existing_runs.map(&:id), repeated_runs.map(&:id)
      end
    end
  end

  test "rejects inactive models without changing the experiment" do
    model = LlmModel.create!(
      gateway: "openrouter",
      provider: "anthropic",
      model_identifier: "anthropic/inactive-test",
      display_name: "Inactive test model",
      active: false
    )

    assert_raises TranslationExperiments::Start::InactiveModelError do
      TranslationExperiments::Start.call(
        experiment: @experiment,
        llm_models: [ model ]
      )
    end

    assert @experiment.reload.pending?
    assert_empty @experiment.translation_runs
  end

  test "rejects unsupported gateways clearly" do
    model = LlmModel.create!(
      gateway: "direct",
      provider: "anthropic",
      model_identifier: "anthropic/direct-test",
      display_name: "Direct test model"
    )

    error = assert_raises TranslationExperiments::Start::UnsupportedGatewayError do
      TranslationExperiments::Start.call(
        experiment: @experiment,
        llm_models: [ model ]
      )
    end

    assert_includes error.message, "direct"
    assert @experiment.reload.pending?
  end
end
