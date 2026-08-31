require "test_helper"

class GlossaryTest < ActiveSupport::TestCase
  def attributes(entries: [ { "source_term" => "Sabbath", "preferred_target_term" => "安息日", "note" => "Keep the biblical term." } ])
    {
      "name" => "Biblical terms",
      "description" => "Translation guidance",
      "source_language" => " Vietnamese ",
      "target_language" => "Japanese",
      "entries" => entries
    }
  end

  test "creates immutable revision with deterministic digest and trimmed values" do
    glossary = Glossaries::Create.call(user: users(:normal), attributes: attributes)
    revision = glossary.current_revision

    assert_equal "Vietnamese", revision.source_language
    assert_equal "Sabbath", revision.entries.first.source_term
    assert_equal Glossaries::ConfigurationDigest.call(revision), revision.configuration_digest
    assert_raises(ActiveRecord::RecordNotSaved) { revision.update!(name: "Changed") }
    assert_raises(ActiveRecord::RecordNotDestroyed) { revision.entries.first.destroy! }
  end

  test "creates new revisions atomically and detects stale editor" do
    glossary = Glossaries::Create.call(user: users(:normal), attributes: attributes)
    second = Glossaries::Revise.call(glossary:, expected_version: "1", attributes: attributes.merge("name" => "Updated"))

    assert_equal 2, second.version
    assert_equal "Biblical terms", glossary.revisions.find_by!(version: 1).name
    assert_raises(Glossaries::Revise::StaleRevisionError) do
      Glossaries::Revise.call(glossary:, expected_version: "1", attributes: attributes)
    end
  end

  test "bounds entries and rejects duplicate literal source terms" do
    glossary = Glossary.new(user: users(:normal))
    duplicate = attributes(entries: [
      { "source_term" => "Word", "preferred_target_term" => "語" },
      { "source_term" => " Word ", "preferred_target_term" => "言葉" }
    ])
    revision = Glossaries::BuildRevision.call(glossary:, version: 1, attributes: duplicate)

    assert_not revision.valid?
    assert_includes revision.errors.full_messages.join, "duplicate source terms"
    assert_raises(Glossaries::BuildRevision::Error) do
      Glossaries::BuildRevision.call(glossary:, version: 1, attributes: attributes(entries: Array.new(101) { |index| { "source_term" => "term#{index}", "preferred_target_term" => "target#{index}" } }))
    end
  end

  test "selects only literal matches with longer overlaps first" do
    glossary = Glossaries::Create.call(user: users(:normal), attributes: attributes(entries: [
      { "source_term" => "Sabbath", "preferred_target_term" => "安息日" },
      { "source_term" => "holy Sabbath", "preferred_target_term" => "聖なる安息日" },
      { "source_term" => "God", "preferred_target_term" => "神" }
    ]))

    entries = Glossaries::RelevantEntries.call(revision: glossary.current_revision, source_text: "The holy Sabbath is sacred.")
    assert_equal [ "holy Sabbath", "Sabbath" ], entries.map(&:source_term)
  end
end
