require "test_helper"

class ProjectTest < ActiveSupport::TestCase
  test "is valid with required attributes" do
    project = Project.new(
      user: users(:normal),
      name: "Vietnamese to Japanese Sermons",
      source_language: "vi",
      target_language: "ja"
    )

    assert project.valid?
  end

  test "requires a name" do
    project = Project.new(
      user: users(:normal),
      source_language: "vi",
      target_language: "ja"
    )

    assert_not project.valid?
    assert project.errors[:name].any?
  end

  test "requires source language" do
    project = Project.new(
      user: users(:normal),
      name: "Sermons",
      target_language: "ja"
    )

    assert_not project.valid?
  end

  test "requires target language" do
    project = Project.new(
      user: users(:normal),
      name: "Sermons",
      source_language: "vi"
    )

    assert_not project.valid?
  end
end
