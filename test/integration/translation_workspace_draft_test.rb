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

    post_draft params: {
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
    post_draft params: {
      project_id: project.id.to_s, workspace: payload("source_text" => "Project-scoped source")
    }, as: :json
    assert_response :success

    get new_translation_workspace_path
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Project-scoped source", count: 0
    get new_translation_workspace_path(project_id: project.id)
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Project-scoped source"

    post_draft params: {
      project_id: projects(:two).id.to_s, workspace: payload
    }, as: :json
    assert_response :not_found
  end

  test "draft API requires authentication and filters the workspace payload from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    assert_equal "[FILTERED]", filter.filter("workspace" => payload("source_text" => "Private"))["workspace"]
    sign_out
    post_draft params: { workspace: payload }, as: :json
    assert_redirected_to login_path
    assert_equal 0, TranslationWorkspaceDraft.count
  end

  test "stale saves and foreign identifiers cannot overwrite a newer owner draft" do
    post_draft params: { workspace: payload }, as: :json
    identity = JSON.parse(response.body)
    post_draft params: {
      draft_id: identity.fetch("id"), version: identity.fetch("version"),
      workspace: payload("project_name" => "Newer")
    }, as: :json
    assert_response :success

    post_draft params: {
      draft_id: identity.fetch("id"), version: identity.fetch("version"),
      workspace: payload("project_name" => "Stale")
    }, as: :json
    assert_response :conflict
    assert_equal "Newer", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")

    sign_out
    sign_in_as users(:other)
    post_draft params: {
      draft_id: identity.fetch("id"), version: 1, workspace: payload
    }, as: :json
    assert_response :conflict
    delete_draft params: { draft_id: identity.fetch("id") }
    assert_response :conflict
  end

  test "rejects malformed, unexpected, and oversized payloads" do
    [ { "source_text" => [ "bad" ] }, { "secret" => "bad" },
      { "source_text" => "x" * (Ai::UsageLimits::MAX_SOURCE_CHARACTERS + 1) },
      { "model_ids" => [ { "nested" => "bad" } ] } ].each do |bad|
      post_draft params: { workspace: payload.merge(bad) }, as: :json
      assert_response :bad_request
    end
    post_draft params: { workspace: payload, admin: "1" }, as: :json
    assert_response :bad_request
    post_draft params: { workspace: payload, draft_id: [ "forged" ] }, as: :json
    assert_response :bad_request
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end


  test "cleanup removes expired drafts while retaining current drafts" do
    post_draft params: { workspace: payload }, as: :json
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
    post_draft params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    draft.update_columns(expires_at: 1.minute.ago)

    get new_translation_workspace_path
    assert_select "input[name='translation_workspace[project_name]'][value='Draft project']", count: 0

    post_draft params: { workspace: payload("project_name" => "Replacement") }, as: :json
    assert_response :success
    assert_equal "Replacement", users(:normal).translation_workspace_drafts.sole.payload.fetch("project_name")
  end

  test "a draft that no longer decrypts is kept but not restored, and is replaced only by the next saved change" do
    other_key = ActiveRecord::Encryption::DerivedSecretKeyProvider.new("a secret key base this deployment no longer has")
    ActiveRecord::Encryption.with_encryption_context(key_provider: other_key) do
      post_draft params: { workspace: payload("source_text" => "Unreadable draft") }, as: :json
    end
    draft = users(:normal).translation_workspace_drafts.sole
    stored = draft.workspace_payload_before_type_cast

    get new_translation_workspace_path
    assert_response :success
    assert_select "p[role='status']", text: /could not be read, so it was not restored/
    assert_select "textarea[name='translation_workspace[source_text]']", text: ""
    assert_select "[data-workspace-guard-needs-save-value='false']"
    assert_select "input[name='translation_workspace_draft_id'][value='#{draft.public_id}']"
    assert_equal stored, draft.reload.workspace_payload_before_type_cast, "rendering never touches the stored draft"

    post_draft params: {
      draft_id: draft.public_id, version: draft.lock_version, workspace: payload("source_text" => "New work")
    }, as: :json
    assert_response :success
    assert_equal "New work", users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text")

    get new_translation_workspace_path
    assert_select "textarea[name='translation_workspace[source_text]']", text: "New work"
  end

  test "an unreadable draft can be discarded" do
    ActiveRecord::Encryption.with_encryption_context(key_provider: ActiveRecord::Encryption::DerivedSecretKeyProvider.new("old secret")) do
      post_draft params: { workspace: payload }, as: :json
    end
    draft = users(:normal).translation_workspace_drafts.sole
    assert_nil draft.readable_payload

    delete_draft params: { draft_id: draft.public_id, version: draft.lock_version }, as: :json
    assert_response :no_content
    assert_not users(:normal).translation_workspace_drafts.exists?
  end

  test "invalid source import is detached on restore while reviewed text remains" do
    post_draft params: {
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
    post_draft params: {
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
    post_draft params: {
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


  test "restore drops unavailable catalog selections and translates its notice" do
    identifiers = [ "anthropic/claude-test", "missing/model" ]
    post_draft params: {
      workspace: payload("model_identifiers" => identifiers)
    }, as: :json
    assert_response :success
    draft = users(:normal).translation_workspace_drafts.sole
    catalog_key = OpenRouter::Catalog::CACHE_KEY
    catalog_model = OpenRouter::Catalog::Model.new(
      identifier: "anthropic/claude-test", name: "Claude Test", provider: "anthropic",
      context_length: 16_000, max_completion_tokens: 4_096,
      prompt_price: 0, completion_price: 0,
      input_modalities: [ "text" ], output_modalities: [ "text" ], supported_parameters: []
    )
    catalog = OpenRouter::Catalog::Result.new(models: [ catalog_model ], fetched_at: Time.current)
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    Rails.cache.write(catalog_key, catalog)
    I18n.with_locale(:vi) do
      restored = TranslationWorkspaceDrafts::Restore.call(draft:, user: users(:normal), project: nil)
      assert_equal [ "anthropic/claude-test" ], restored.attributes.fetch(:model_identifiers)
      assert_equal I18n.t("workspace_ui.draft_configuration_changed"), restored.configuration_notice
    end

    Rails.cache.delete(catalog_key)
    I18n.with_locale(:ja) do
      restored = TranslationWorkspaceDrafts::Restore.call(draft:, user: users(:normal), project: nil)
      assert_equal identifiers, restored.attributes.fetch(:model_identifiers)
      assert_nil restored.configuration_notice
    end
  ensure
    Rails.cache = original_cache if original_cache
  end

  test "a new import keeps unrelated saved settings while replacing source fields" do
    post_draft params: {
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
    post_draft params: { workspace: payload }, as: :json
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
    post_draft params: { workspace: payload }, as: :json
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
    post_draft params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    stale_version = draft.lock_version
    draft.update!(workspace_payload: JSON.generate(payload("project_name" => "Newer")))
    delete_draft params: {
      draft_id: draft.public_id, version: stale_version
    }
    assert_response :conflict
    assert_equal "Newer", draft.reload.payload.fetch("project_name")
  end

  test "discard removes only the current owner's draft" do
    post_draft params: { workspace: payload }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    delete_draft params: { draft_id: draft.public_id, version: draft.lock_version }
    assert_response :no_content
    assert_not TranslationWorkspaceDraft.exists?(draft.id)
  end

  # The dangerous sequence: save A commits but its response never reaches the
  # browser, so the browser still believes no draft (or an older version)
  # exists. Discarding A's response here is exactly the browser's knowledge
  # after a dropped connection; the server-side commit is real.
  test "a committed save whose response was lost never refuses or regresses the next edit" do
    editor = new_editor_id
    post_draft params: {
      editor_id: editor, sequence: 1, draft_id: "", version: "", workspace: payload("source_text" => "Edit A")
    }, as: :json
    assert_response :success

    post_draft params: {
      editor_id: editor, sequence: 2, draft_id: "", version: "", workspace: payload("source_text" => "Edit B")
    }, as: :json
    assert_response :success
    identity = JSON.parse(response.body)
    draft = users(:normal).translation_workspace_drafts.sole
    assert_equal [ draft.public_id, draft.lock_version, 2 ], identity.values_at("id", "version", "sequence")

    get new_translation_workspace_path
    assert_select "textarea[name='translation_workspace[source_text]']", text: "Edit B"
    assert_select "input[name='translation_workspace_draft_version'][value='#{draft.lock_version}']"
  end

  test "an update whose response was lost lets the same page keep saving from its stale version" do
    editor = new_editor_id
    post_draft params: { editor_id: editor, sequence: 1, workspace: payload }, as: :json
    acknowledged = JSON.parse(response.body)

    post_draft params: {
      editor_id: editor, sequence: 2, draft_id: acknowledged["id"], version: acknowledged["version"],
      workspace: payload("source_text" => "Committed but unacknowledged")
    }, as: :json
    assert_response :success
    post_draft params: {
      editor_id: editor, sequence: 3, draft_id: acknowledged["id"], version: acknowledged["version"],
      workspace: payload("source_text" => "Latest edit")
    }, as: :json

    assert_response :success
    assert_equal "Latest edit", users(:normal).translation_workspace_drafts.sole.payload.fetch("source_text")
  end

  test "a replayed or late duplicate save is acknowledged without writing or regressing" do
    editor = new_editor_id
    first = { editor_id: editor, sequence: 1, workspace: payload("source_text" => "Edit A") }
    post_draft params: first, as: :json
    draft = users(:normal).translation_workspace_drafts.sole
    written_at = draft.updated_at

    post_draft params: first, as: :json
    assert_response :success
    assert_equal [ draft.public_id, draft.lock_version, 1 ], JSON.parse(response.body).values_at("id", "version", "sequence")
    assert_equal [ draft.lock_version, written_at ], draft.reload.then { [ it.lock_version, it.updated_at ] }

    post_draft params: { editor_id: editor, sequence: 3, workspace: payload("source_text" => "Edit C") }, as: :json
    post_draft params: { editor_id: editor, sequence: 2, workspace: payload("source_text" => "Late B") }, as: :json
    assert_response :success
    assert_equal 3, JSON.parse(response.body).fetch("sequence")
    assert_equal "Edit C", draft.reload.payload.fetch("source_text")
    assert_equal 1, users(:normal).translation_workspace_drafts.count
  end

  test "another tab cannot overwrite the newer draft until it reloads the current version" do
    tab_one = new_editor_id
    tab_two = new_editor_id
    post_draft params: { editor_id: tab_one, sequence: 1, workspace: payload("source_text" => "Tab one") }, as: :json
    draft = users(:normal).translation_workspace_drafts.sole

    post_draft params: { editor_id: tab_two, sequence: 1, workspace: payload("source_text" => "Stale tab two") }, as: :json
    assert_response :conflict
    post_draft params: {
      editor_id: tab_two, sequence: 2, draft_id: draft.public_id, version: draft.lock_version + 1,
      workspace: payload("source_text" => "Guessing tab two")
    }, as: :json
    assert_response :conflict
    assert_equal "Tab one", draft.reload.payload.fetch("source_text")

    post_draft params: {
      editor_id: new_editor_id, sequence: 1, draft_id: draft.public_id, version: draft.lock_version,
      workspace: payload("source_text" => "Reloaded tab two")
    }, as: :json
    assert_response :success
    post_draft params: {
      editor_id: tab_one, sequence: 2, draft_id: draft.public_id, version: draft.lock_version,
      workspace: payload("source_text" => "Tab one again")
    }, as: :json
    assert_response :conflict
    assert_equal "Reloaded tab two", draft.reload.payload.fetch("source_text")
  end

  test "the page that saved last can discard or launch its draft without having seen the latest identity" do
    editor = new_editor_id
    post_draft params: { editor_id: editor, sequence: 1, workspace: payload }, as: :json
    delete_draft params: { sequence: 0, editor_id: new_editor_id, draft_id: "", version: "" }
    assert_response :conflict
    delete_draft params: { sequence: 1, editor_id: editor, draft_id: "", version: "" }
    assert_response :no_content
    assert_equal 0, users(:normal).translation_workspace_drafts.count
    delete_draft params: { sequence: 1, editor_id: editor, draft_id: "", version: "" }
    assert_response :conflict
    editor = new_editor_id

    post_draft params: { editor_id: editor, sequence: 2, workspace: payload("project_name" => "Lost response") }, as: :json
    post_draft params: { editor_id: editor, sequence: 2, workspace: payload("project_name" => "Lost response") }, as: :json
    identity = JSON.parse(response.body)
    assert_enqueued_jobs 1, only: TranslationRunJob do
      post translation_workspace_path, params: {
        translation_workspace: {
          project_name: "Lost response", source_language: "Vietnamese", target_language: "Japanese",
          document_title: "Draft document", source_text: "Private source", instruction_prompt: "Translate faithfully",
          model_ids: [ llm_models(:openrouter_claude).id ], submission_token: issue_translation_workspace_token
        },
        translation_workspace_draft_id: identity["id"], translation_workspace_draft_version: identity["version"]
      }
    end
    assert_response :redirect
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end

  test "rejects malformed editor identities without writing" do
    [
      { editor_id: "not-hex", sequence: 1 }, { editor_id: "A" * 32, sequence: 1 }, { editor_id: new_editor_id, sequence: 0 },
      { editor_id: new_editor_id }, { sequence: 1 }, { editor_id: new_editor_id, sequence: 2**60 },
      { editor_id: [ new_editor_id ], sequence: 1 }, { editor_id: new_editor_id, sequence: [ 1 ] }
    ].each do |identity|
      post_draft params: identity.merge(workspace: payload), as: :json
      assert_response :bad_request, identity.inspect
    end
    assert_equal 0, users(:normal).translation_workspace_drafts.count
  end

  test "discard after response loss rejects every old-page save and permits a fresh page" do
    editor = new_editor_id
    submitted = { editor_id: editor, sequence: 1, draft_id: "", version: "", workspace: payload }
    post_draft params: submitted, as: :json
    assert_response :success
    delete_draft params: { editor_id: editor, sequence: 1 }, as: :json
    assert_response :no_content
    3.times do
      post_draft params: submitted, as: :json
      assert_response :conflict
      assert_empty users(:normal).translation_workspace_drafts.reload
    end
    post_draft params: submitted.merge(sequence: 2), as: :json
    assert_response :conflict
    post_draft params: submitted.merge(editor_id: new_editor_id, sequence: 1), as: :json
    assert_response :success
  end

  test "discard before first-save delivery retires every sequence the page already started" do
    editor = new_editor_id
    delete_draft params: { editor_id: editor, sequence: 2 }, as: :json
    assert_response :no_content
    [ 1, 2 ].each do |sequence|
      post_draft params: { editor_id: editor, sequence:, workspace: payload }, as: :json
      assert_response :conflict
    end
    assert_empty users(:normal).translation_workspace_drafts.reload
    post_draft params: { editor_id: editor, sequence: 3, workspace: payload }, as: :json
    assert_response :conflict
    fresh_editor = new_editor_id
    post_draft params: { editor_id: fresh_editor, sequence: 3, workspace: payload }, as: :json
    assert_response :success
    delete_draft params: { editor_id: editor, sequence: 2 }, as: :json
    assert_response :conflict
    assert_equal 3, users(:normal).translation_workspace_drafts.reload.sole.editor_sequence
  end

  test "discard preserves earlier editor watermarks and expiry cleanup cannot resurrect their old saves" do
    first, second = new_editor_id, new_editor_id
    post_draft params: { editor_id: first, sequence: 1, workspace: payload }, as: :json
    identity = response.parsed_body
    post_draft params: { editor_id: second, sequence: 1, draft_id: identity.fetch("id"), version: identity.fetch("version"), workspace: payload }, as: :json
    assert_response :success
    delete_draft params: { editor_id: second, sequence: 1 }, as: :json
    assert_response :no_content
    post_draft params: { editor_id: first, sequence: 1, workspace: payload }, as: :json
    assert_response :conflict
    post_draft params: { editor_id: second, sequence: 2, workspace: payload }, as: :json
    assert_response :conflict
    second = new_editor_id
    post_draft params: { editor_id: second, sequence: 2, workspace: payload }, as: :json
    assert_response :success
    users(:normal).translation_workspace_drafts.sole.update_columns(expires_at: 1.minute.ago)
    TranslationWorkspaceDraftCleanupJob.perform_now
    post_draft params: { editor_id: second, sequence: 2, workspace: payload }, as: :json
    assert_response :conflict
    assert_empty users(:normal).translation_workspace_drafts.reload
  end

  private

  # Each implicit identity models a freshly loaded page. Explicit identities
  # retain their delivery sequence in replay/malformed-input tests.
  def post_draft(params:, **options)
    post translation_workspace_draft_path, params: admitted_params(params, sequence: 1), **options
  end

  def delete_draft(params: {}, **options)
    delete translation_workspace_draft_path, params: admitted_params(params, sequence: 0), **options
  end

  def admitted_params(params, sequence:)
    return params if params.key?(:editor_id) || params.key?(:sequence)

    user = User.find_by(id: signed_in_user_id) || users(:normal)
    context_key = params[:project_id].present? ? "project:#{params[:project_id]}" : "new"
    { editor_id: ReplayIdentity.issue(user:, context_key:), sequence: }.merge(params)
  end


  def payload(overrides = {})
    {
      "project_name" => "Draft project", "source_language" => "Vietnamese",
      "target_language" => "Japanese", "document_title" => "Draft document",
      "source_text" => "Private source", "instruction_prompt" => "Translate faithfully",
      "workflow_mode" => "manual", "model_ids" => [], "model_identifiers" => [],
      "translation_reference_revision_ids" => []
    }.merge(overrides)
  end

  def new_editor_id
    ReplayIdentity.issue(user: users(:normal), context_key: "new")
  end
end
