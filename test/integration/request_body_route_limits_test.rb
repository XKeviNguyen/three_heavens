require "test_helper"
require_relative "../support/final_translation_test_helper"
require_relative "../support/methodology_profile_test_helper"

# Forms reach the application only within the body limit of their route.
# These submit the largest legitimate form for each long-text route through
# the full stack, and show that an ordinary route no longer accepts an
# upload-sized body.
class RequestBodyRouteLimitsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper
  include MethodologyProfileTestHelper

  # Four UTF-8 bytes, twelve once percent-encoded: the most expensive character.
  WIDE = "😀".freeze

  test "a signed-out multipart body on an ordinary route is refused before Rails parses it" do
    boundary = "RouteLimitBoundary"
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"a.txt\"\r\n" \
      "Content-Type: text/plain\r\n\r\n#{'a' * (1024 * 1024)}\r\n--#{boundary}--\r\n"

    %w[/projects /workflow_profiles /settings/models /nonexistent].each do |path|
      post path, params: body, headers: { "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}" }
      assert_response :content_too_large
    end
  end

  test "an upload-sized body still reaches the upload routes" do
    sign_in_as users(:normal)
    file = Rack::Test::UploadedFile.new(StringIO.new("a" * (9 * 1024 * 1024)), "text/plain", original_filename: "large.txt")

    post source_imports_path, params: { source_import: { source_file: file, request_key: ReplayIdentity.issue } }

    assert_not_equal 413, response.status
  end

  test "the largest final translation revision saves" do
    sign_in_as users(:normal)
    final_translation = create_final_translation_workspace
    content = WIDE * FinalTranslationVersion::MAX_CONTENT_LENGTH

    patch save_revision_final_translation_path(final_translation), params: {
      final_translation: { content:, change_note: WIDE * FinalTranslationVersion::MAX_CHANGE_NOTE_LENGTH,
                           expected_version_number: final_translation.current_version.version_number }
    }

    assert_redirected_to final_translation_path(final_translation)
    assert_equal content, final_translation.reload.current_version.content
  end

  test "the largest glossary saves" do
    sign_in_as users(:normal)
    entries = Array.new(GlossaryRevision::MAXIMUM_ENTRIES) do |index|
      { source_term: "#{index}#{WIDE * 195}", preferred_target_term: WIDE * 200, note: WIDE * 500 }
    end

    assert_difference -> { Glossary.count }, 1 do
      post glossaries_path, params: { glossary: {
        name: WIDE * 150, description: WIDE * 500, source_language: "Vietnamese", target_language: "Japanese", entries:
      } }
    end
    assert_response :redirect
  end

  test "the largest methodology profile saves" do
    sign_in_as users(:normal)

    assert_difference -> { MethodologyProfile.count }, 1 do
      post methodology_profiles_path, params: { methodology_profile: methodology_profile_attributes.merge(
        guidance: WIDE * MethodologyProfileRevision::MAXIMUM_GUIDANCE_CHARACTERS, description: WIDE * 500
      ) }
    end
    assert_response :redirect
  end

  # The launch itself may be refused by the model's context budget; the form
  # must still reach the application rather than stop at the body limit.
  test "the largest workspace form reaches the application" do
    sign_in_as users(:normal)
    params = { translation_workspace: {
      project_name: WIDE * 150, source_language: "Vietnamese", target_language: "Japanese",
      document_title: WIDE * 255, source_text: WIDE * Ai::UsageLimits::MAX_SOURCE_CHARACTERS, experiment_name: WIDE * 150,
      instruction_prompt: WIDE * Ai::UsageLimits::MAX_INSTRUCTION_CHARACTERS, workflow_mode: "manual",
      model_ids: [ llm_models(:openrouter_claude).id.to_s ], submission_token: issue_translation_workspace_token
    } }
    assert_operator Rack::Utils.build_nested_query(params).bytesize, :>, RequestBodyLimit::DEFAULT_MAX_BYTES

    post translation_workspace_path, params: params

    assert_response :unprocessable_content
    assert_select "#translation_workspace_source_text", text: params.dig(:translation_workspace, :source_text)
  end
end
