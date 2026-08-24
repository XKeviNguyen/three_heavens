require "test_helper"

class ExperimentTest < ActiveSupport::TestCase
  setup do
    project = Project.create!(
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
    experiment = @document.experiments.create!

    assert experiment.pending?
  end

  test "can transition to running" do
    experiment = @document.experiments.create!

    experiment.running!

    assert experiment.running?
  end

  test "rejects unsupported status" do
    experiment = @document.experiments.build(status: "banana")

    assert_not experiment.valid?
  end
end
