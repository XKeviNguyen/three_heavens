require "test_helper"
require_relative "../support/document_io_test_helper"

class TranslationWorkspaceDraftTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include DocumentIoTestHelper

  setup do
    sign_in_as users(:normal)
  end

  test "saves an encrypted owner draft without starting any AI work and restores it" do
    source = "Private draft source: 現在の文書"
    counts = [ AiProviderAttempt, TranslationRun, PipelineRun, Experiment, LlmModel ].map(&:count)

    post translation_workspace_draft_path, params: {
      workspace: payload("source_text" => source, "model_ids" => [ llm_models(:openrouter_claude).id.to_s ])
    }, as: :json

    assert_response :success
    draft = users(:normal).translation_workspace_drafts.sole
    assert_equal [ AiProviderAttempt, TranslationRun, PipelineRun, Experiment, LlmModel ].map(&:count), counts
    assert_equal source, draft.payload.fetch("source_text")
    raw = ActiveRecord::Base.connection.select_value(
      "SELECT workspace_payload FROM translation_workspace_drafts WHERE id = #{draft.id}"
    )
    assert_not_includes raw, source
    assert_not_equal JSON.generate(draft.payload), raw
    assert_equal "no-store", response.headers["Cache-Control"]

    get new_translation_workspace_path
    assert_response :success
    assert_select "input[name='translation_workspace[project_name]'][value='Draft project']"
    assert_select "textarea[name='translation_workspace[source_text]']", text: source
    assert_select "input[name='translation_workspace_draft_id'][value='#{draft.public_id}']"
    assert_select "p", text: /Draft restored/
    assert_not_includes response.body, raw
  end


  test "draft contexts are isolated per owned project" do
    project = projects(:one)
    post translation_workspace_draft_path, params: {
      project_id: project.id.to_s, workspace: payload("source_text" => "Project-scoped source")
    }, as: :json
    assert_response :success

    get new_translation_workspace_path
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Project-scoped source", count: 0
    get new_translation_workspace_path(project_id: project.id)
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Project-scoped source"

    post translation_workspace_draft_path, params: {
      project_id: projects(:two).id.to_s, workspace: payload
    }, as: :json
    assert_response :not_found
  end

  test "draft API requires authentication and filters the workspace payload from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("workspace" => payload("source_text" => "Private"))["workspace"]
    sign_out
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    assert_redirected_to login_path
    assert_equal 0, TranslationWorkspaceDraft.count
  end

  test "stale saves and foreign identifiers cannot overwrite a newer owner draft" do
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    identity = JSON.parse(response.body)
    post translation_workspace_draft_path, params: {
      draft_id: identity.fetch("id"), version: identity.fetch("version"),
      workspace: payload("project_name" => "Newer")
    }, as: :json
    assert_response :success

    post translation_workspace_draft_path, params: {
      draft_id: identity.fetch("id"), version: identity.fetch("version"),
      workspace: payload("project_name" => "Stale")
    }, as: :json
    assert_response :conflict
    assert_equal "Newer", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")

    sign_out
    sign_in_as users(:other)
    post translation_workspace_draft_path, params: {
      draft_id: identity.fetch("id"), version: 1, workspace: payload
    }, as: :json
    assert_response :not_found
    delete translation_workspace_draft_path, params: { draft_id: identity.fetch("id") }
    assert_response :not_found
  end

  test "rejects malformed, unexpected, and oversized payloads" do
    [ { "source_text" => [ "bad" ] }, { "secret" => "bad" },
      { "source_text" => "x" * (Ai::UsageLimits::MAX_SOURCE_CHARACTERS + 1) },
      { "model_ids" => [ { "nested" => "bad" } ] } ].each do |bad|
      post translation_workspace_draft_path, params: { workspace: payload.merge(bad) }, as: :json
      assert_response :bad_request
    end
    post translation_workspace_draft_path, params: { workspace: payload, admin: "1" }, as: :json
    assert_response :bad_request
    post translation_workspace_draft_path, params: { workspace: payload, draft_id: [ "forged" ] }, as: :json
    assert_response :bad_request
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end


  test "cleanup removes expired drafts while retaining current drafts" do
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    expired = users(:normal).translation_workspace_drafts.sole
    expired.update_columns(expires_at: 1.minute.ago)
    current = users(:other).translation_workspace_drafts.create!(
      context_key: "new", workspace_payload: JSON.generate(payload),
      expires_at: 1.day.from_now
    )

    TranslationWorkspaceDraftCleanupJob.perform_now
    assert_not TranslationWorkspaceDraft.exists?(expired.id)
    assert TranslationWorkspaceDraft.exists?(current.id)
  end

  test "expired drafts do not restore and can be replaced" do
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    draft.update_columns(expires_at: 1.minute.ago)

    get new_translation_workspace_path
    assert_select "input[name='translation_workspace[project_name]'][value='Draft project']", count: 0

    post translation_workspace_draft_path, params: { workspace: payload("project_name" => "Replacement") }, as: :json
    assert_response :success
    assert_equal "Replacement", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "invalid source import is detached on restore while reviewed text remains" do
    post translation_workspace_draft_path, params: {
      workspace: payload("source_import_id" => "999999999", "source_text" => "Reviewed private text")
    }, as: :json
    get new_translation_workspace_path
    assert_response :success
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Reviewed private text"
    assert_select "input[name='translation_workspace[source_import_id]']", count: 1
    assert_select "input[name='translation_workspace[source_import_id]'][value='999999999']", count: 0
    assert_select "p", text: /original upload is no longer attached/
  end



  test "ready import restore reissues its project binding and expiry detaches it" do
    source_import = create_ready_import(user: users(:normal), text: "Original imported text")
    post translation_workspace_draft_path, params: {
      workspace: payload("source_import_id" => source_import.id.to_s, "source_text" => "Reviewed imported text")
    }, as: :json
    get new_translation_workspace_path
    assert_response :success
    assert_select "input[name='translation_workspace[source_import_id]'][value='#{source_import.id}']"
    binding = css_select("input[name='translation_workspace[source_import_project_token]']").sole["value"]
    assert SourceImports::ProjectBinding.valid?(token: binding, source_import:, project: nil)
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Reviewed imported text"

    source_import.update_columns(expires_at: 1.minute.ago)
    get new_translation_workspace_path
    assert_response :success
    assert_select "input[name='translation_workspace[source_import_id]'][value='#{source_import.id}']", count: 0
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Reviewed imported text"
    assert_select "p", text: /original upload is no longer attached/
  end

  test "unavailable saved configuration is removed while unrelated draft state remains" do
    post translation_workspace_draft_path, params: {
      workspace: payload(
        "glossary_revision_id" => "999999999",
        "methodology_profile_revision_id" => "999999999",
        "translation_reference_revision_ids" => [ "999999999" ],
        "model_ids" => [ "999999999" ],
        "source_text" => "Keep this reviewed source"
      )
    }, as: :json
    get new_translation_workspace_path
    assert_response :success
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Keep this reviewed source"
    assert_select "input[name='translation_workspace[glossary_revision_id]'][value='999999999']", count: 0
    assert_select "input[name='translation_workspace[methodology_profile_revision_id]'][value='999999999']", count: 0
    assert_select "p", text: /Some saved configuration is no longer available/
  end


  test "a new import keeps unrelated saved settings while replacing source fields" do
    post translation_workspace_draft_path, params: {
      workspace: payload("source_text" => "Older source", "project_name" => "Keep project")
    }, as: :json
    source_import = create_ready_import(user: users(:normal), text: "Fresh imported text", filename: "fresh.txt")
    get new_translation_workspace_path(
      source_import_id: source_import.id,
      source_import_project_token: source_import_binding(source_import)
    )
    assert_response :success
    assert_select "input[name='translation_workspace[project_name]'][value='Keep project']"
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Fresh imported text"
    assert_select "input[name='translation_workspace[document_title]'][value='fresh']"
  end

  test "a failed launch from a stale tab does not adopt a newer draft version" do
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    post translation_workspace_path, params: {
      translation_workspace: {
        project_name: "", source_language: "Vietnamese", target_language: "Japanese",
        document_title: "Old form", source_text: "Old local source",
        instruction_prompt: "Old instructions", submission_token: issue_translation_workspace_token
      }
    }
    assert_response :unprocessable_content
    assert_select "input[name='translation_workspace_draft_id'][value='']"
    assert_equal "Private source", draft.reload.payload.fetch("source_text")
  end

  test "validation failure retains draft and successful durable launch consumes it" do
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    attributes = {
      project_name: "Draft project", source_language: "Vietnamese", target_language: "Japanese",
      document_title: "Draft document", source_text: "Private source", experiment_name: "Draft launch",
      instruction_prompt: "Translate faithfully", model_ids: [ llm_models(:openrouter_claude).id ],
      submission_token: issue_translation_workspace_token
    }
    post translation_workspace_path, params: {
      translation_workspace: attributes.merge(project_name: ""),
      translation_workspace_draft_id: draft.public_id, translation_workspace_draft_version: draft.lock_version
    }
    assert_response :unprocessable_content
    assert draft.reload

    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: attributes,
        translation_workspace_draft_id: draft.public_id, translation_workspace_draft_version: draft.lock_version
      }
    end
    assert_response :redirect
    assert_not TranslationWorkspaceDraft.exists?(draft.id)
  end


  test "stale discard cannot delete a newer draft" do
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    stale_version = draft.lock_version
    draft.update!(workspace_payload: JSON.generate(payload("project_name" => "Newer")))
    delete translation_workspace_draft_path, params: {
      draft_id: draft.public_id, version: stale_version
    }
    assert_response :conflict
    assert_equal "Newer", draft.reload.payload.fetch("project_name")
  end

  test "discard removes only the current owner's draft" do
    post translation_workspace_draft_path, params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    delete translation_workspace_draft_path, params: { draft_id: draft.public_id, version: draft.lock_version }
    assert_response :no_content
    assert_not TranslationWorkspaceDraft.exists?(draft.id)
  end

  private

  def payload(overrides = {})
    {
      "project_name" => "Draft project", "source_language" => "Vietnamese",
      "target_language" => "Japanese", "document_title" => "Draft document",
      "source_text" => "Private source", "instruction_prompt" => "Translate faithfully",
      "workflow_mode" => "manual", "model_ids" => [], "model_identifiers" => [],
      "translation_reference_revision_ids" => []
    }.merge(overrides)
  end
end
