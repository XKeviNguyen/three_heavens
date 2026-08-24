require "test_helper"

class TranslationRunTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(
      name: "Vietnamese to Japanese Sermons",
      source_language: "vi",
      target_language: "ja"
    )

    document = project.documents.create!(
      title: "The Sabbath",
      source_text: "Source theological text"
    )

    @experiment = document.experiments.create!(
      instruction_prompt: "Translate faithfully."
    )
    @llm_model = llm_models(:openrouter_claude)
  end

  test "is valid with experiment and llm model" do
    run = @experiment.translation_runs.build(
      llm_model: @llm_model
    )

    assert run.valid?
    assert run.pending?
  end

  test "requires llm model" do
    run = @experiment.translation_runs.build

    assert_not run.valid?
    assert run.errors[:llm_model].any?
  end

  test "can transition to running" do
    run = @experiment.translation_runs.create!(
      llm_model: @llm_model
    )

    run.running!

    assert run.running?
  end

  test "prevents duplicate models within an experiment" do
    @experiment.translation_runs.create!(llm_model: @llm_model)
    duplicate = @experiment.translation_runs.build(llm_model: @llm_model)

    assert_not duplicate.valid?
    assert duplicate.errors[:llm_model_id].any?
  end

  test "database index prevents duplicate models within an experiment" do
    @experiment.translation_runs.create!(llm_model: @llm_model)
    duplicate = @experiment.translation_runs.build(llm_model: @llm_model)

    assert_raises ActiveRecord::RecordNotUnique do
      duplicate.save!(validate: false)
    end
  end
end
