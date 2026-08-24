require "test_helper"

class DocumentTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(
      name: "Vietnamese to Japanese Sermons",
      source_language: "vi",
      target_language: "ja"
    )
  end

  test "is valid with required attributes" do
    document = @project.documents.build(
      title: "The Sabbath",
      source_text: "Source theological text"
    )

    assert document.valid?
  end

  test "requires title" do
    document = @project.documents.build(
      source_text: "Source theological text"
    )

    assert_not document.valid?
  end

  test "requires source text" do
    document = @project.documents.build(
      title: "The Sabbath"
    )

    assert_not document.valid?
  end
end
