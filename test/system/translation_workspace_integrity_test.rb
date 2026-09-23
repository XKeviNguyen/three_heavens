require "application_system_test_case"
require "tempfile"
require_relative "../support/translation_reference_test_helper"
require_relative "../support/methodology_profile_test_helper"
require_relative "../support/workflow_profile_test_helper"

class TranslationWorkspaceIntegrityTest < ApplicationSystemTestCase
  include TranslationReferenceTestHelper
  include MethodologyProfileTestHelper
  include WorkflowProfileTestHelper

  setup do
    @reference = create_translation_reference
    @methodology = create_methodology_profile
    @workflow = create_workflow_profile
    @glossary = Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        name: "Workspace terms",
        source_language: "Vietnamese",
        target_language: "Japanese",
        entries: [ { source_term: "Grace", preferred_target_term: "恵み" } ]
      }
    )
    sign_in_in_browser
  end

  test "primary fields and auxiliary editor have separate real DOM form owners" do
    visit root_path
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    names = %w[
      project_name source_language target_language document_title source_text
      experiment_name instruction_prompt workflow_mode glossary_revision_id
      translation_reference_revision_ids methodology_profile_revision_id
      guidance_preference model_identifiers
    ]
    owners = page.evaluate_script(<<~JS)
      #{names.to_json}.map(name => {
        const input = document.querySelector(`[name^="translation_workspace[${name}]"]`)
        return [name, input?.form?.id || null]
      })
    JS
    assert_equal names.map { |name| [ name, "workspace-form" ] }, owners
    assert_equal "workspace-form", page.evaluate_script("document.querySelector('#workspace-launch input[type=submit]').form.id")
    assert_equal 0, page.evaluate_script("document.querySelectorAll('#workspace-form form').length")
    assert_equal 0, page.evaluate_script("document.querySelectorAll('#source-upload-panel form').length")

    click_link "+ Add terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    assert_equal 0, page.evaluate_script("document.querySelectorAll('#workspace-form form').length")
    assert_nil page.evaluate_script("document.querySelector('dialog[open] form').closest('#workspace-form')")
  end

  test "canceled navigation preserves a populated workspace" do
    visit root_path
    fill_in "Project name", with: "Protected project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Protected source"
    fill_in "Source text", with: "Long source text that must not disappear."
    fill_in "Translation name", with: "Protected translation"
    fill_in "Instructions for the translation", with: "Preserve the meaning."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"
    assert_current_path root_path
    assert_field "Project name", with: "Protected project"
    assert_field "Source text", with: "Long source text that must not disappear."
    assert_field "Instructions for the translation", with: "Preserve the meaning."
    assert_selector "#workspace-manual-models [data-model-card]", count: 1
    assert_checked_field "translation_workspace[translation_reference_revision_ids][]"
    assert_checked_field "translation_workspace[methodology_profile_revision_id]"
    assert_checked_field "translation_workspace[glossary_revision_id]", visible: :all

    click_link "Projects"
    click_button "Leave without saving"
    assert_current_path projects_path
  end

  test "browser Back does not silently discard a changed workspace" do
    visit projects_path
    click_link "New translation"
    assert_current_path new_translation_workspace_path
    fill_in "Project name", with: "Back protected"

    page.go_back
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Stay"
    assert_current_path new_translation_workspace_path
    assert_field "Project name", with: "Back protected"
    click_link "Projects"
    assert_selector "dialog[open]", text: "Leave this translation?"
    click_button "Leave without saving"
    assert_current_path projects_path
  end

  test "pristine workspace navigates without a warning" do
    visit root_path
    click_link "Projects"
    assert_current_path projects_path
    assert_no_selector "dialog[open]", text: "Leave this translation?"
  end

  test "workspace controls preserve the populated source and configuration" do
    visit root_path
    page.execute_script("window.__workspaceErrors = []; window.addEventListener('error', event => window.__workspaceErrors.push(event.message)); window.addEventListener('unhandledrejection', event => window.__workspaceErrors.push(String(event.reason)))")
    fill_in "Project name", with: "Control project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Control source"
    fill_in "Source text", with: "Substantial source text for interaction checks."
    fill_in "Translation name", with: "Control translation"
    fill_in "Instructions for the translation", with: "Translate with care."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    assert_selector "#workspace-glossary", text: "Workspace terms"
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end
    assert_core_state

    target = find_field("Target language")
    target.fill_in with: "fren"
    target.send_keys(:arrow_down, :enter)
    assert_field "Target language", with: "French"
    assert_core_state(target_language: "French")
    target.fill_in with: "japan"
    target.send_keys(:arrow_down, :enter)
    assert_core_state

    click_button "Swap languages"
    assert_core_state(source_language: "Japanese", target_language: "Vietnamese")
    click_button "Swap languages"
    assert_core_state

    click_button "Upload file"
    assert_selector "#source-upload-panel", visible: true
    assert_core_state
    click_button "Paste text"
    assert_core_state

    find("details > summary", text: /References, methodology/).click
    assert_core_state
    find("details > summary", text: /References, methodology/).click

    within "#workspace-manual-models" do
      search = find("input[placeholder='Search OpenRouter models…']")
      search.fill_in with: "claude"
      assert_selector "[role='option']", text: /Claude/
      search.fill_in with: ""
      find("select[data-model-browser-target='provider']").select("anthropic")
      assert_selector "[role='option']", text: /Anthropic/
      find("select[data-model-browser-target='provider']").select("All providers")
      assert_equal "true", search[:'aria-expanded']
    end
    find_field("Project name").click
    assert_equal "false", find("#workspace-manual-models input[placeholder='Search OpenRouter models…']")[:'aria-expanded']
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "[role='option']", visible: true
    end
    assert_core_state

    choose "Automatic"
    choose "translation_workspace_workflow_profile_revision_id_#{@workflow.current_revision_id}"
    assert_core_state
    choose "Manual"
    assert_core_state

    click_link "Edit terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    click_button "Cancel"
    assert_core_state

    click_link "Edit terminology"
    within "dialog[open]" do
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈悲"
      click_button "Save terminology"
    end
    assert_no_selector "dialog[open]"
    assert_equal 2, @glossary.reload.current_revision.version
    assert_core_state

    click_link "+ Add terminology"
    assert_selector "dialog[open] form[action='#{workspace_terminology_path}']"
    within "dialog[open]" do
      fill_in "Glossary name", with: "New workspace terms"
      fill_in "Source language", with: "Vietnamese"
      fill_in "Target language", with: "Japanese"
      first("input[name='glossary[entries][][source_term]']").fill_in with: "Mercy"
      first("input[name='glossary[entries][][preferred_target_term]']").fill_in with: "慈しみ"
      click_button "Create & select"
    end
    assert_no_selector "dialog[open]"
    assert_core_state(glossary_name: "New workspace terms")
    assert_empty page.evaluate_script("window.__workspaceErrors")
  end

  test "success failure and removal of an import preserve unrelated workspace fields" do
    visit root_path
    fill_in "Project name", with: "Import project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Japanese")
    fill_in "Document title", with: "Original title"
    fill_in "Source text", with: "Prior pasted source"
    fill_in "Translation name", with: "Import translation"
    fill_in "Instructions for the translation", with: "Keep nuance."
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    click_button "Upload file"
    bad = Tempfile.new([ "bad-source", ".pdf" ])
    bad.write("%PDF-1.4 not allowed")
    bad.flush
    attach_file "Source file", bad.path
    click_button "Upload and review"
    assert_text /not supported|TXT|DOCX|Markdown/i
    assert_field "Project name", with: "Import project"
    assert_field "Source text", with: "Prior pasted source", visible: :all
    assert_selector "#workspace-manual-models [data-model-card]", count: 1

    good = Tempfile.new([ "good-source", ".txt" ])
    good.write("Imported source")
    good.flush
    attach_file "Source file", good.path
    click_button "Upload and review"
    assert_field "Reviewed source text", with: "Imported source"
    assert_field "Project name", with: "Import project"
    assert_field "Translation name", with: "Import translation"
    assert_field "Instructions for the translation", with: "Keep nuance."
    assert_selector "#workspace-manual-models [data-model-card]", count: 1
    assert_selector "#workspace-source-import", visible: true

    click_button "Remove import"
    assert_no_selector "#workspace-source-import", visible: true
    assert_field "Source text", with: "Imported source"
    assert_field "Project name", with: "Import project"
    assert_selector "#workspace-manual-models [data-model-card]", count: 1
  ensure
    bad&.close!
    good&.close!
  end

  test "server validation keeps workspace selections and source text" do
    visit root_path
    fill_in "Project name", with: "Validation project"
    choose_language("Source language", "Vietnamese")
    choose_language("Target language", "Vietnamese")
    fill_in "Document title", with: "Validation source"
    fill_in "Source text", with: "Source retained after server validation."
    fill_in "Translation name", with: "Validation translation"
    fill_in "Instructions for the translation", with: "Retain these instructions."
    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{@glossary.current_revision_id}']", visible: :all).choose
    find("details > summary", text: /References, methodology/).click
    find("input[name='translation_workspace[translation_reference_revision_ids][]']").check
    find("input[name='translation_workspace[methodology_profile_revision_id]'][value='#{@methodology.current_revision_id}']").choose
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    click_button "Start translation"
    assert_selector "#form-errors-heading"
    assert_field "Project name", with: "Validation project"
    assert_field "Source text", with: "Source retained after server validation."
    assert_field "Instructions for the translation", with: "Retain these instructions."
    assert_checked_field "translation_workspace[glossary_revision_id]", visible: :all
    assert_checked_field "translation_workspace[translation_reference_revision_ids][]", visible: :all
    assert_checked_field "translation_workspace[methodology_profile_revision_id]", visible: :all
    assert_selector "#workspace-manual-models [data-model-card]", count: 1
  end

  test "contextual help supports hover keyboard touch escape and outside dismissal" do
    visit root_path
    hint = find("[aria-label='More information about Source language']")
    tooltip = find("##{hint[:'aria-describedby']}", visible: :all)
    hint.hover
    assert tooltip.visible?
    find("h1").hover
    assert_not tooltip.visible?

    page.execute_script("arguments[0].focus()", hint)
    assert tooltip.visible?
    hint.send_keys(:escape)
    assert_not tooltip.visible?
    assert_equal "false", hint[:'aria-expanded']

    page.execute_script("arguments[0].dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, pointerType: 'touch' })); arguments[0].click()", hint)
    assert tooltip.visible?
    find("h1").click
    assert_not tooltip.visible?
    page.execute_script("arguments[0].blur(); arguments[0].focus()", hint)
    assert tooltip.visible?
  end

  private

  def sign_in_in_browser
    visit login_path
    fill_in "Email", with: users(:normal).email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  def assert_core_state(source_language: "Vietnamese", target_language: "Japanese", glossary_name: "Workspace terms")
    assert_field "Project name", with: "Control project"
    assert_field "Source language", with: source_language
    assert_field "Target language", with: target_language
    assert_field "Document title", with: "Control source", visible: :all
    assert_field "Source text", with: "Substantial source text for interaction checks.", visible: :all
    assert_field "Translation name", with: "Control translation"
    assert_field "Instructions for the translation", with: "Translate with care."
    assert_selector "#workspace-manual-models [data-model-card]", count: 1, visible: :all
    assert_checked_field "translation_workspace[translation_reference_revision_ids][]", visible: :all
    assert_checked_field "translation_workspace[methodology_profile_revision_id]", visible: :all
    assert_selector "[data-workspace-summary-target='terminology']", text: glossary_name
  end

  def choose_language(label, value)
    field = find_field(label)
    field.fill_in with: value
    field.send_keys(:escape)
  end
end
