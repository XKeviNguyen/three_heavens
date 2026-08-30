require "test_helper"

class Ai::SegmentAggregationTest < ActiveSupport::TestCase
  test "telemetry sums known physical values and marks any missing field incomplete" do
    complete = telemetry_run(cost: BigDecimal("0.1"))
    incomplete = telemetry_run(cost: BigDecimal("0.2"), reasoning_tokens: nil)

    attributes = Ai::SegmentAggregation.telemetry_attributes([ complete, incomplete ])

    assert_equal 20, attributes.fetch(:prompt_tokens)
    assert_nil attributes.fetch(:reasoning_tokens)
    assert_equal BigDecimal("0.3"), attributes.fetch(:cost)
    assert_not attributes.fetch(:telemetry_complete)
  end

  test "bounded joins disclose omitted segment data within the exact limit" do
    joined = Ai::SegmentAggregation.bounded_join([ "a" * 40, "b" * 40 ], maximum: 75)

    assert_equal 75, joined.length
    assert_includes joined, "Additional segment data omitted"
  end

  test "logical model resolution is present only when every physical call agrees" do
    same = [ Struct.new(:model).new("provider/model"), Struct.new(:model).new("provider/model") ]
    mixed = same + [ Struct.new(:model).new("provider/alternate") ]

    assert_equal "provider/model", Ai::SegmentAggregation.common_value(same, :model)
    assert_nil Ai::SegmentAggregation.common_value(mixed, :model)
  end

  private

  def telemetry_run(overrides)
    defaults = {
      prompt_tokens: 10,
      completion_tokens: 5,
      total_tokens: 15,
      cached_tokens: 0,
      reasoning_tokens: 0,
      cost: BigDecimal("0.1")
    }
    Struct.new(*defaults.keys, keyword_init: true).new(**defaults.merge(overrides))
  end
end
