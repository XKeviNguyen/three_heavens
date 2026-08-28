require "test_helper"

class FilterParameterLoggingTest < ActiveSupport::TestCase
  test "filters authentication and translation request bodies without filtering generic content" do
    filtered = ActiveSupport::ParameterFilter.new(
      Rails.application.config.filter_parameters
    ).filter(
      "password" => "password-value",
      "source_text" => "source-value",
      "extracted_text" => "extracted-value",
      "preview_text" => "preview-value",
      "source_file" => "binary-value",
      "instruction_prompt" => "instruction-value",
      "final_translation" => {
        "content" => "final-value",
        "change_note" => "note-value"
      },
      "unrelated" => { "content" => "operational-value" }
    )

    assert_equal "[FILTERED]", filtered["password"]
    assert_equal "[FILTERED]", filtered["source_text"]
    assert_equal "[FILTERED]", filtered["extracted_text"]
    assert_equal "[FILTERED]", filtered["preview_text"]
    assert_equal "[FILTERED]", filtered["source_file"]
    assert_equal "[FILTERED]", filtered["instruction_prompt"]
    assert_equal "[FILTERED]", filtered.dig("final_translation", "content")
    assert_equal "[FILTERED]", filtered.dig("final_translation", "change_note")
    assert_equal "operational-value", filtered.dig("unrelated", "content")
  end
end
