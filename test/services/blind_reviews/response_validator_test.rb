require "test_helper"

class BlindReviews::ResponseValidatorTest < ActiveSupport::TestCase
  setup do
    @labels = [ "Candidate A", "Candidate B" ]
  end

  test "accepts exactly one valid structured evaluation per expected candidate" do
    result = validate(valid_content)

    assert_equal @labels, result.map { |evaluation| evaluation["candidate_label"] }
    assert_equal 9, result.first["overall_score"]
  end

  test "rejects malformed JSON" do
    assert_invalid("not-json")
  end

  test "rejects missing duplicate and unknown candidates" do
    assert_invalid(JSON.generate(evaluations: [ valid_evaluation("Candidate A") ]))
    assert_invalid(JSON.generate(evaluations: [
      valid_evaluation("Candidate A"), valid_evaluation("Candidate A")
    ]))
    assert_invalid(JSON.generate(evaluations: [
      valid_evaluation("Candidate A"), valid_evaluation("Candidate C")
    ]))
  end

  test "rejects missing extra and wrong-typed fields" do
    missing = valid_evaluation("Candidate A").except("strengths")
    extra = valid_evaluation("Candidate A").merge("private_reasoning" => "hidden")
    wrong_type = valid_evaluation("Candidate A").merge("issues" => [ "issue" ])

    [ missing, extra, wrong_type ].each do |invalid_evaluation|
      assert_invalid(JSON.generate(evaluations: [
        invalid_evaluation, valid_evaluation("Candidate B")
      ]))
    end
  end

  test "rejects noninteger and out-of-range scores" do
    [ 0, 11, 9.5, "9", nil ].each do |score|
      invalid_evaluation = valid_evaluation("Candidate A").merge(
        "faithfulness_score" => score
      )
      assert_invalid(JSON.generate(evaluations: [
        invalid_evaluation, valid_evaluation("Candidate B")
      ]))
    end
  end

  test "rejects invalid root structures" do
    assert_invalid(JSON.generate([]))
    assert_invalid(JSON.generate(evaluations: {}, extra: true))
  end

  private

  def validate(content)
    BlindReviews::ResponseValidator.call(
      content: content,
      expected_labels: @labels
    )
  end

  def assert_invalid(content)
    error = assert_raises BlindReviews::ResponseValidator::Error do
      validate(content)
    end
    assert_equal "invalid_review_response", error.code
  end

  def valid_content
    JSON.generate(evaluations: @labels.map { |label| valid_evaluation(label) })
  end

  def valid_evaluation(label)
    {
      "candidate_label" => label,
      "faithfulness_score" => 9,
      "naturalness_score" => 8,
      "terminology_score" => 9,
      "instruction_adherence_score" => 8,
      "overall_score" => 9,
      "strengths" => "Faithful and clear.",
      "issues" => "One phrase is awkward.",
      "recommended_corrections" => "Revise that phrase.",
      "suggested_translation" => nil
    }
  end
end
