require "test_helper"

class LongDocuments::SegmenterTest < ActiveSupport::TestCase
  test "segments multilingual text deterministically and reconstructs every character" do
    source = [
      "Đức Chúa Trời yêu thương thế gian.\n\n",
      "神は世を愛された。教会は応答する！\n",
      "Emoji remain intact 🙏🏽✨.\n\n",
      "Một đoạn rất dài không có ranh giới " + ("x" * 700)
    ].join

    first = LongDocuments::Segmenter.call(source, target_characters: 256)
    second = LongDocuments::Segmenter.call(source, target_characters: 256)

    assert_equal source, first.sum("", &:source_text)
    assert_equal first.map(&:source_text), second.map(&:source_text)
    assert_equal first.map(&:source_sha256), second.map(&:source_sha256)
    assert_equal (1..first.size).to_a, first.map(&:position)
    assert first.all? { |segment| segment.source_text.valid_encoding? }
    assert first.all? { |segment| segment.source_text.length <= 256 }
  end

  test "honors exact boundary and boundary plus one without loss" do
    exact = "語" * 256
    over = exact + "🙂"

    assert_equal [ exact ], LongDocuments::Segmenter.call(exact, target_characters: 256).map(&:source_text)
    assert_equal [ exact, "🙂" ], LongDocuments::Segmenter.call(over, target_characters: 256).map(&:source_text)
  end

  test "rejects empty source and unsafe targets" do
    assert_raises(ArgumentError) { LongDocuments::Segmenter.call("") }
    assert_raises(ArgumentError) { LongDocuments::Segmenter.call("text", target_characters: 255) }
  end
end
