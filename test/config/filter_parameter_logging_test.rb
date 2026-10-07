require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  test "filters owner guidance used in provider prompts" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      "methodology_profile" => { "guidance" => "private methodology" },
      "glossary" => { "entries" => [ {
        "source_term" => "private source term",
        "preferred_target_term" => "private target term",
        "note" => "private terminology guidance"
      } ] }
    )

    assert_equal "[FILTERED]", filtered.dig("methodology_profile", "guidance")
    assert_equal [ "[FILTERED]" ] * 3, filtered.dig("glossary", "entries").sole.values
  end

  test "filters authentication and translation request bodies without filtering generic content" do
    filtered = ActiveSupport::ParameterFilter.new(
      Rails.application.config.filter_parameters
    ).filter(
      "password" => "password-value",
      "submission_token" => "opaque-launch-value",
      "request_key" => "opaque-upload-value",
      "creation_key" => "opaque-reference-value",
      "editor_id" => "opaque-editor-value",
      "source_text" => "source-value",
      "extracted_text" => "extracted-value",
      "preview_text" => "preview-value",
      "source_file" => "binary-value",
      "instruction_prompt" => "instruction-value",
      "approved_translation" => "approved-value",
      "approved_translation_file" => "approved-binary-value",
      "final_translation" => {
        "content" => "final-value",
        "change_note" => "note-value"
      },
      "unrelated" => { "content" => "operational-value" }
    )

    assert_equal "[FILTERED]", filtered["password"]
    assert_equal "[FILTERED]", filtered["submission_token"]
    assert_equal "[FILTERED]", filtered["request_key"]
    assert_equal "[FILTERED]", filtered["creation_key"]
    assert_equal "[FILTERED]", filtered["editor_id"]
    assert_equal "[FILTERED]", filtered["source_text"]
    assert_equal "[FILTERED]", filtered["extracted_text"]
    assert_equal "[FILTERED]", filtered["preview_text"]
    assert_equal "[FILTERED]", filtered["source_file"]
    assert_equal "[FILTERED]", filtered["instruction_prompt"]
    assert_equal "[FILTERED]", filtered["approved_translation"]
    assert_equal "[FILTERED]", filtered["approved_translation_file"]
    assert_equal "[FILTERED]", filtered.dig("final_translation", "content")
    assert_equal "[FILTERED]", filtered.dig("final_translation", "change_note")
    assert_equal "operational-value", filtered.dig("unrelated", "content")
  end

  test "logs any other long value truncated and short values unchanged" do
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(
      "unknown" => "x" * 5_000, "page" => "2"
    )

    assert_equal "#{"x" * 200}[TRUNCATED]", filtered["unknown"]
    assert_equal "2", filtered["page"]
  end
end
