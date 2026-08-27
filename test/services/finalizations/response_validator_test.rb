require "test_helper"

class Finalizations::ResponseValidatorTest < ActiveSupport::TestCase
  test "accepts the exact strict response" do
    result = validate(valid_payload)
    assert_equal "Complete refined translation", result.fetch("proposed_translation")
  end

  test "rejects malformed missing extra wrong type and blank proposals" do
    invalid = [ "not-json" ]
    missing = valid_payload
    missing.delete(:warnings)
    invalid << missing
    extra = valid_payload
    extra[:reasoning] = "hidden"
    invalid << extra
    wrong_type = valid_payload
    wrong_type[:change_summary] = "changed"
    invalid << wrong_type
    blank = valid_payload
    blank[:proposed_translation] = " "
    invalid << blank

    invalid.each do |payload|
      assert_raises Finalizations::ResponseValidator::Error do
        validate(payload)
      end
    end
  end

  test "rejects proposal and list size item type and item length violations" do
    variants = []
    proposal = valid_payload
    proposal[:proposed_translation] = "x" * (FinalTranslationVersion::MAX_CONTENT_LENGTH + 1)
    variants << proposal
    too_many = valid_payload
    too_many[:warnings] = Array.new(Finalizations::ResponseValidator::MAX_LIST_ITEMS + 1, "warning")
    variants << too_many
    wrong_item = valid_payload
    wrong_item[:terminology_notes] = [ 1 ]
    variants << wrong_item
    long_item = valid_payload
    long_item[:change_summary] = [ "x" * (Finalizations::ResponseValidator::MAX_ITEM_LENGTH + 1) ]
    variants << long_item

    variants.each do |payload|
      assert_raises Finalizations::ResponseValidator::Error do
        validate(payload)
      end
    end
  end

  private

  def validate(payload)
    content = payload.is_a?(String) ? payload : JSON.generate(payload)
    Finalizations::ResponseValidator.call(content: content)
  end

  def valid_payload
    {
      proposed_translation: "Complete refined translation",
      change_summary: [ "Improved clarity" ],
      terminology_notes: [ "Preserved key term" ],
      warnings: []
    }
  end
end
