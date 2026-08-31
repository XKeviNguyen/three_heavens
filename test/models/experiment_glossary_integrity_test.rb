require "test_helper"

class ExperimentGlossaryIntegrityTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class RequestCountingClient
    attr_reader :requests

    def initialize
      @requests = 0
    end

    def chat_completion(**)
      @requests += 1
      raise "Provider request must not occur"
    end
  end

  test "accepts a same-owner matching glossary" do
    project = project_for(users(:normal))
    glossary = glossary_for(users(:normal))

    experiment = project.documents.create!(title: "Source", source_text: "Sabbath").experiments.create!(
      instruction_prompt: "Translate faithfully.",
      glossary_revision: glossary.current_revision
    )

    assert_equal glossary.current_revision, experiment.glossary_revision
  end

  test "rejects another owner's same-language glossary without scheduling provider work" do
    project = project_for(users(:normal))
    foreign_glossary = glossary_for(users(:other))
    experiment = project.documents.create!(title: "Source", source_text: "Sabbath").experiments.create!(instruction_prompt: "Translate faithfully.")
    experiment.update_column(:glossary_revision_id, foreign_glossary.current_revision_id)
    experiment.reload
    model = llm_models(:openrouter_claude)
    client = RequestCountingClient.new
    original_factory = TranslationRunJob.client_factory
    TranslationRunJob.client_factory = -> { client }

    assert_not experiment.valid?
    assert_includes experiment.errors[:glossary_revision], "is not available for this experiment"
    assert_no_enqueued_jobs do
      assert_raises(ActiveRecord::RecordInvalid) do
        TranslationExperiments::Start.call(experiment: experiment, llm_models: [ model ])
      end
    end
    assert_empty experiment.translation_runs
    assert_equal 0, client.requests
  ensure
    TranslationRunJob.client_factory = original_factory if original_factory
  end

  test "admin cannot attach another user's glossary to a private experiment" do
    project = project_for(users(:admin))
    glossary = glossary_for(users(:normal))
    experiment = project.documents.create!(title: "Source", source_text: "Sabbath").experiments.build(
      instruction_prompt: "Translate faithfully.",
      glossary_revision: glossary.current_revision
    )

    assert_not experiment.valid?
    assert_includes experiment.errors[:glossary_revision], "is not available for this experiment"
  end

  private

  def project_for(user)
    user.projects.create!(name: "Private project", source_language: "Vietnamese", target_language: "Japanese")
  end

  def glossary_for(user)
    Glossaries::Create.call(
      user: user,
      attributes: {
        "name" => "Terms", "source_language" => "Vietnamese", "target_language" => "Japanese",
        "entries" => [ { "source_term" => "Sabbath", "preferred_target_term" => "安息日" } ]
      }
    )
  end
end
