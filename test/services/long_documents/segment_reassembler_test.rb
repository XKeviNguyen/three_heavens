require "test_helper"

class LongDocuments::SegmentReassemblerTest < ActiveSupport::TestCase
  Segment = Data.define(:position, :source_text)

  test "owns exact join boundaries without changing internal or final content" do
    parts = [
      [ Segment.new(position: 2, source_text: "source two\n"), "二" ],
      [ Segment.new(position: 1, source_text: "source one\n\n"), "Một nội\nbộ\n\n\n" ],
      [ Segment.new(position: 3, source_text: "source three"), "Final  " ]
    ]

    assembled = LongDocuments::SegmentReassembler.call(parts)

    assert_equal "Một nội\nbộ\n\n二\nFinal  ", assembled
  end

  test "does not invent a separator for a hard source split" do
    parts = [
      [ Segment.new(position: 1, source_text: "abc"), "translated " ],
      [ Segment.new(position: 2, source_text: "def"), "continuation" ]
    ]

    assert_equal "translatedcontinuation", LongDocuments::SegmentReassembler.call(parts)
  end
end
