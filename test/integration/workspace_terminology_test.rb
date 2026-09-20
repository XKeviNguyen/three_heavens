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
    assert_select "turbo-frame#workspace-terminology" do
      assert_select "form[action='#{workspace_terminology_path}']"
      assert_select "input[name='glossary_id'][value='#{@glossary.id}']"
      assert_select "input[name='glossary[entries][][source_term]'][value='Sabbath']"
      assert_select "input[type='submit'][value='Save terminology']"
    end
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
