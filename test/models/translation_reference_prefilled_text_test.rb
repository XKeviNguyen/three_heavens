require "test_helper"

class TranslationReferencePrefilledTextTest < ActiveSupport::TestCase
  setup do
    @reference = TranslationReferences::Create.call(user: users(:normal), attributes: {
      title: "Prefilled", source_language: "Vietnamese", target_language: "Japanese",
      source_text: "Dòng một.\nDòng hai.", approved_translation: "一行目。"
    })
    @version = @reference.current_revision.version.to_s
  end

  test "text equal to the revision the form was based on is prefilled, whatever its line endings" do
    assert @reference.prefilled_text?(@version, "source_text", "Dòng một.\nDòng hai.")
    assert @reference.prefilled_text?(@version, "source_text", "Dòng một.\r\nDòng hai."), "browsers submit CRLF"
    assert @reference.prefilled_text?(@version, "approved_translation", "一行目。")
  end

  test "changed text, another version, or no version is not prefilled" do
    assert_not @reference.prefilled_text?(@version, "source_text", "Dòng một.")
    assert_not @reference.prefilled_text?("999", "source_text", "Dòng một.\nDòng hai.")
    assert_not @reference.prefilled_text?(nil, "source_text", "Dòng một.\nDòng hai.")
    assert_not @reference.prefilled_text?("x", "source_text", "Dòng một.\nDòng hai.")
  end
end
