require "test_helper"

class WorkspaceTerminologyTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:normal)
    sign_in_as @user
    @glossary = Glossaries::Create.call(user: @user, attributes: glossary_attributes)
  end

  test "renders the inline editor inside the workspace terminology frame" do
    get edit_workspace_terminology_path(glossary_id: @glossary.id)

    assert_response :success
    assert_select "turbo-frame#workspace-terminology-editor" do
      assert_select "form[action='#{workspace_terminology_path}']"
      assert_select "input[name='glossary_id'][value='#{@glossary.id}']"
      assert_select "input[name='glossary[entries][][source_term]'][value='Sabbath']"
      assert_select "input[type='submit'][value='Save terminology']"
    end
  end

  test "creates and selects terminology inline without provider work" do
    get new_workspace_terminology_path(source_language: "Vietnamese", target_language: "Japanese")

    assert_response :success
    assert_select "turbo-frame#workspace-terminology-editor" do
      assert_select "form[action='#{workspace_terminology_path}']"
      assert_select "input[name='glossary[source_language]'][value='Vietnamese']"
      assert_select "input[name='glossary[target_language]'][value='Japanese']"
    end

    assert_no_difference -> { AiProviderAttempt.count } do
      assert_difference -> { Glossary.count }, 1 do
        assert_difference -> { GlossaryRevision.count }, 1 do
          post workspace_terminology_path, params: {
            glossary: {
              name: "Inline sermon terms",
              description: "Created in the workspace",
              source_language: "Vietnamese",
              target_language: "Japanese",
              entries: [ { source_term: "Grace", preferred_target_term: "恵み", note: "Preferred" } ]
            }
          }
        end
      end
    end

    assert_response :created
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, "Inline sermon terms"
    created = Glossary.order(:id).last
    assert_includes response.body, "value=\"#{created.current_revision_id}\""
  end

  test "inline save creates a new immutable revision and preserves the old one" do
    old_revision = @glossary.current_revision
    original_entry = old_revision.entries.sole

    assert_no_difference -> { AiProviderAttempt.count } do
      assert_difference -> { GlossaryRevision.count }, 1 do
        patch workspace_terminology_path, params: {
          glossary_id: @glossary.id,
          glossary: {
            expected_version: old_revision.version.to_s,
            entries: [
              { source_term: "Sabbath", preferred_target_term: "安息日", note: "Standard term" },
              { source_term: "Grace", preferred_target_term: "恵み", note: "" }
            ]
          }
        }
      end
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, "workspace-terminology"

    @glossary.reload
    assert_equal 2, @glossary.current_revision.version
    assert_equal 2, @glossary.current_revision.entries.size
    assert_equal "安息日", original_entry.reload.preferred_target_term
    assert_equal 1, old_revision.reload.version
  end

  test "stale expected version is rejected without creating a revision" do
    assert_no_difference -> { GlossaryRevision.count } do
      patch workspace_terminology_path, params: {
        glossary_id: @glossary.id,
        glossary: {
          expected_version: "999",
          entries: [ { source_term: "Sabbath", preferred_target_term: "安息日", note: "" } ]
        }
      }
    end

    assert_response :conflict
  end

  test "rejected duplicate normalized entries preserve every submitted field and removal" do
    entries = [
      { source_term: "  ân điển  ", preferred_target_term: "恵み🙂", note: "変更 & <draft>" },
      { source_term: "ân điển", preferred_target_term: "恩恵", note: "Tiếng Việt e\u0301" },
      { source_term: "新しい", preferred_target_term: "新規", note: "追加" }
    ]
    version = @glossary.current_revision.version.to_s
    assert_no_difference -> { GlossaryRevision.count } do
      patch workspace_terminology_path, params: {
        glossary_id: @glossary.id, glossary: { expected_version: version, entries: }
      }
    end
    assert_response :unprocessable_content
    assert_select "[role=alert]", text: /duplicate/i
    assert_submitted_entries(entries)
    assert_select "input[name='glossary[expected_version]'][value='#{version}']"
    assert_equal "Sabbath", @glossary.reload.current_revision.entries.sole.source_term
  end

  test "stale edit preserves submitted values and stale token without overwriting the winner" do
    version = @glossary.current_revision.version.to_s
    Glossaries::Revise.call(glossary: @glossary, expected_version: version, attributes: glossary_attributes.merge(
      entries: [ { source_term: "Winner", preferred_target_term: "勝者", note: "Current" } ]
    ))
    entries = [ { source_term: "Losing edit", preferred_target_term: "編集", note: "Keep my work" } ]
    assert_no_difference -> { GlossaryRevision.count } do
      patch workspace_terminology_path, params: {
        glossary_id: @glossary.id, glossary: { expected_version: version, entries: }
      }
    end
    assert_response :conflict
    assert_select "[role=alert]", text: /changed while you were editing/
    assert_submitted_entries(entries)
    assert_select "input[name='glossary[expected_version]'][value='#{version}']"
    assert_equal "Winner", @glossary.reload.current_revision.entries.sole.source_term
  end

  test "rejected blank fields retain entries and their exact field values" do
    entries = [ { source_term: "", preferred_target_term: "", note: "Removed old term" } ]
    assert_no_difference -> { GlossaryRevision.count } do
      patch workspace_terminology_path, params: {
        glossary_id: @glossary.id,
        glossary: { expected_version: @glossary.current_revision.version, entries: }
      }
    end
    assert_response :unprocessable_content
    assert_submitted_entries(entries)
  end

  test "rejects malformed entries and unexpected parameters" do
    assert_no_difference -> { GlossaryRevision.count } do
      patch workspace_terminology_path, params: {
        glossary_id: @glossary.id,
        glossary: {
          expected_version: @glossary.current_revision.version.to_s,
          entries: "not-a-list"
        }
      }
    end
    assert_response :bad_request
  end

  test "another owner's glossary is not accessible" do
    foreign = Glossaries::Create.call(user: users(:other), attributes: glossary_attributes)

    get edit_workspace_terminology_path(glossary_id: foreign.id)
    assert_response :not_found

    patch workspace_terminology_path, params: {
      glossary_id: foreign.id,
      glossary: {
        expected_version: foreign.current_revision.version.to_s,
        entries: [ { source_term: "Sabbath", preferred_target_term: "安息日", note: "" } ]
      }
    }
    assert_response :not_found
  end

  private

  def assert_submitted_entries(entries)
    %i[source_term preferred_target_term note].each do |key|
      assert_select "[data-glossary-entries-target=list] input[name='glossary[entries][][#{key}]']" do |inputs|
        assert_equal entries.map { |entry| entry.fetch(key) }, inputs.map { |input| input["value"] }
      end
    end
  end

  def glossary_attributes
    {
      name: "Rehearsal terminology",
      description: "Inline editing",
      source_language: "Vietnamese",
      target_language: "Japanese",
      entries: [ { source_term: "Sabbath", preferred_target_term: "安息日", note: "Initial" } ]
    }
  end
end
