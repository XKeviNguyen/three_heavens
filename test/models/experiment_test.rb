require "test_helper"

class ExperimentTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(
      user: users(:normal),
      name: "Vietnamese to Japanese Sermons",
      source_language: "vi",
      target_language: "ja"
    )

    @document = project.documents.create!(
      title: "The Sabbath",
      source_text: "Source theological text"
    )
  end

  test "defaults to pending" do
    experiment = @document.experiments.create!(
      instruction_prompt: "Translate faithfully."
    )

    assert experiment.pending?
  end

  test "can transition to running" do
    experiment = @document.experiments.create!(
      instruction_prompt: "Translate faithfully."
    )

    experiment.running!

    assert experiment.running?
  end

  test "rejects unsupported status" do
    experiment = @document.experiments.build(
      instruction_prompt: "Translate faithfully.",
      status: "banana"
    )

    assert_not experiment.valid?
  end

  test "requires an instruction prompt" do
    experiment = @document.experiments.build

    assert_not experiment.valid?
    assert experiment.errors[:instruction_prompt].any?
  end
end
