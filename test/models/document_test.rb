require "test_helper"

class DocumentTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(
      user: users(:normal),
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
    assert document.pasted_text?
    assert_not document.source_file.attached?
  end

  test "uploaded provenance must be complete and attached" do
    document = @project.documents.build(
      title: "Imported",
      source_text: "Reviewed",
      source_kind: :uploaded_file,
      source_format: "txt"
    )

    assert_not document.valid?
    assert_includes document.errors[:original_filename], "must be present for an uploaded source"
    assert_includes document.errors[:source_file], "must be attached for an uploaded source"
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
