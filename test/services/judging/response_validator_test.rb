require "test_helper"

class Judging::ResponseValidatorTest < ActiveSupport::TestCase
  LABELS = [ "Candidate A", "Candidate B" ].freeze

  test "accepts a strict complete ranking" do
    result = validate(valid_payload)
    assert_equal "Candidate A", result.fetch("winner_label")
  end

  test "rejects malformed missing duplicate unknown and extra candidate data" do
    invalid_payloads = []
    invalid_payloads << "not-json"
    missing = valid_payload
    missing[:rankings] = missing[:rankings].first(1)
    invalid_payloads << JSON.generate(missing)
    duplicate = valid_payload
    duplicate[:rankings][1][:candidate_label] = "Candidate A"
    invalid_payloads << JSON.generate(duplicate)
    unknown = valid_payload
    unknown[:rankings][1][:candidate_label] = "Candidate Z"
    invalid_payloads << JSON.generate(unknown)
    extra = valid_payload
    extra[:unexpected] = true
    invalid_payloads << JSON.generate(extra)

    invalid_payloads.each do |content|
      assert_raises Judging::ResponseValidator::Error do
        Judging::ResponseValidator.call(content: content, expected_labels: LABELS)
      end
    end
  end

  test "rejects rank score winner type and length violations" do
    variants = []
    duplicate_rank = valid_payload
    duplicate_rank[:rankings][1][:rank] = 1
    variants << duplicate_rank
    mismatch = valid_payload
    mismatch[:winner_label] = "Candidate B"
    variants << mismatch
    score = valid_payload
    score[:rankings][0][:overall_score] = 101
    variants << score
    wrong_type = valid_payload
    wrong_type[:confidence_score] = "high"
    variants << wrong_type
    too_long = valid_payload
    too_long[:winner_rationale] = "x" * 5_001
    variants << too_long
    extra_ranking_key = valid_payload
    extra_ranking_key[:rankings][0][:reasoning] = "hidden"
    variants << extra_ranking_key

    variants.each do |payload|
      assert_raises Judging::ResponseValidator::Error do
        validate(payload)
      end
    end
  end

  private

  def validate(payload)
    content = payload.is_a?(String) ? payload : JSON.generate(payload)
    Judging::ResponseValidator.call(content: content, expected_labels: LABELS)
  end

  def valid_payload
    {
      rankings: LABELS.each_with_index.map do |label, index|
        {
          candidate_label: label,
          rank: index + 1,
          overall_score: 90 - (index * 10),
          rationale: "Rationale",
          strengths: "Strengths",
          risks: "Risks"
        }
      end,
      winner_label: "Candidate A",
      winner_rationale: "Best overall.",
      confidence_score: 90
    }
  end
end
