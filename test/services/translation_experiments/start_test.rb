require "test_helper"

class TranslationExperiments::StartTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class RequestCountingClient
    attr_reader :request_count

    def initialize
      @request_count = 0
    end

    def chat_completion(**)
      @request_count += 1
      raise "Provider request must not occur"
    end
  end

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

  test "rejects insufficient output capability before scheduling or provider work" do
    model = llm_models(:openrouter_claude)
    model.update!(context_window_tokens: 64_000, max_output_tokens: 4_095)
    client = RequestCountingClient.new
    original_factory = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }

    assert_no_enqueued_jobs do
      error = assert_raises(TranslationExperiments::Start::ContextBudgetError) do
        TranslationExperiments::Start.call(experiment: @experiment, llm_models: [ model ])
      end
      assert_includes error.message, "required translation output reserve"
    end

    assert_equal 0, client.request_count
    assert_empty @experiment.reload.translation_runs
    assert @experiment.pending?
  ensure
    TranslationRunJob.client_factory = original_factory if original_factory
  end

  test "fails closed before scheduling when relevant glossary data exceeds context" do
    entries = Array.new(GlossaryRevision::MAXIMUM_ENTRIES) do |index|
      { "source_term" => "term#{index}", "preferred_target_term" => "t" * 200, "note" => "n" * 500 }
    end
    glossary = Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        "name" => "Large terms", "source_language" => "vi", "target_language" => "ja", "entries" => entries
      }
    )
    document = @experiment.document.project.documents.create!(
      title: "Glossary source",
      source_text: entries.map { |entry| entry.fetch("source_term") }.join(" ")
    )
    experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully.",
      glossary_revision: glossary.current_revision
    )
    model = llm_models(:openrouter_claude)
    model.update!(context_window_tokens: 16_384, max_output_tokens: 4_096)
    client = RequestCountingClient.new
    original_factory = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }

    assert_no_enqueued_jobs do
      assert_raises TranslationExperiments::Start::ContextBudgetError do
        TranslationExperiments::Start.call(experiment: experiment, llm_models: [ model ])
      end
    end
    assert_empty experiment.reload.translation_runs
    assert_equal 0, client.request_count
  ensure
    TranslationRunJob.client_factory = original_factory if original_factory
  end
end
