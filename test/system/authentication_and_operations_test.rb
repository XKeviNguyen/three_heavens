require "application_system_test_case"
require "tempfile"
require_relative "../support/final_translation_test_helper"

class AuthenticationAndOperationsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  test "unauthenticated visitor is taken to sign in" do
    visit new_translation_workspace_path

    assert_text "Sign in"
    assert_text "Please sign in to continue."
  end

  test "normal user signs in and cannot access admin settings" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")

    assert_text "New translation"
    assert_no_link "Models"
    visit settings_models_path
    assert_text "You are not authorized to access administration settings."
    assert_current_path root_path
  end

  test "admin reaches model settings and operations" do
    sign_in_in_browser(users(:admin), "admin secure password value")

    click_link "Models"
    assert_text "OpenRouter model catalog"
    click_link "Operations"
    assert_text "AI workflow operations"
  end

  test "owner explicitly retries a failed translation without a provider call" do
    experiment = failed_experiment_for(users(:normal))
    failed_run = experiment.translation_runs.failed.first
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    visit experiment_path(experiment)

    assert_text "Recover failed translations"
    assert_text "incur additional cost"
    assert_enqueued_with(job: TranslationRunJob, args: [ failed_run.id ]) do
      accept_confirm(/up to 5 new provider attempts/) do
        click_button "Retry failed translations"
      end
      assert_text "Queued 1 failed translation run(s) for retry."
    end
    assert failed_run.reload.pending?
    assert_equal 1, experiment.translation_runs.count
  end

  test "owner uploads previews edits and consumes a TXT source without AI during preview" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    click_button "Upload file"
    assert_text "Source file"

    source = Tempfile.new([ "browser-source", ".txt" ])
    source.binmode
    source.write("Browser upload\r\n日本語")
    source.flush

    assert_no_enqueued_jobs only: TranslationRunJob do
      attach_file "Source file", source.path
      click_button "Upload and review"
      assert_selector "#workspace-source-import", text: /browser-source/
      assert_field "Reviewed source text", with: "Browser upload\n日本語"
    end

    fill_in "Reviewed source text", with: "Reviewed browser source\n日本語"
    fill_in "Project name", with: "Browser import"
    choose_known_language "Source language", "Vietnamese"
    choose_known_language "Target language", "Japanese"
    fill_in "Document title", with: "Browser source"
    fill_in "Translation name", with: "Browser secure import"
    fill_in "Instructions for the translation", with: "Translate faithfully."
    within "#workspace-manual-models" do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add"
      first("button", text: "Add").click
    end

    assert_enqueued_jobs 1, only: TranslationRunJob do
      click_button "Start translation"
      assert_text "Translation experiment"
      assert_text "Reviewed browser source"
      assert_link "Original source file"
    end

    document = Document.order(:id).last
    assert document.uploaded_file?
    assert_equal "Reviewed browser source\n日本語", document.source_text
  ensure
    source&.close!
  end

  test "normal pasted source workflow still starts an experiment" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    glossary = create_browser_glossary
    FileUtils.mkdir_p(Rails.root.join("tmp/ux_review"))

    page.current_window.resize_to(1440, 1000)
    visit new_translation_workspace_path
    assert_selector "aside#app-sidebar", visible: true
    assert_selector "aside#app-sidebar", text: "Three Heavens"
    assert_no_selector "button[data-action='sidebar#open']", visible: true
    layout_columns = page.evaluate_script("getComputedStyle(document.querySelector('#workspace-layout')).gridTemplateColumns")
    desktop_metrics = page.evaluate_script("({ width: window.innerWidth, rootFont: getComputedStyle(document.documentElement).fontSize, media: matchMedia('(min-width: 75rem)').matches, className: document.querySelector('#workspace-layout').className, sheets: Array.from(document.styleSheets).map((sheet) => sheet.href) })")
    assert_operator layout_columns.split.size, :>=, 2, "Expected desktop workspace split, got #{layout_columns.inspect} with #{desktop_metrics.inspect}"

    source_language = find_field("Source language")
    source_language.send_keys("viet", :arrow_down, :enter)
    assert_equal "Vietnamese", source_language.value
    source_language.send_keys(:escape)
    assert_no_selector "#translation_workspace_source_language-list", visible: true

    target_language = find_field("Target language")
    target_language.send_keys("japan", :arrow_down, :enter)
    assert_equal "Japanese", target_language.value
    target_language.send_keys(:escape)
    assert_selector "[data-workspace-summary-target='language']", text: "Vietnamese → Japanese"
    page.save_screenshot(Rails.root.join("tmp/ux_review/desktop-1440-new-translation.png"))

    assert_selector "#workspace-manual-models div[role='option']", minimum: 10
    assert_selector "#workspace-manual-models button", text: "Add", minimum: 1
    within "#workspace-manual-models" do
      first("button", text: "Add").click
      assert_text "1 model selected"
    end
    assert_selector "[data-workspace-summary-target='models']", text: "1 selected"
    scroll_to find("#workspace-manual-models")
    page.save_screenshot(Rails.root.join("tmp/ux_review/desktop-1440-model-browser.png"))

    find("#workspace-glossary summary", text: "Choose saved glossary").click
    find("input[name='translation_workspace[glossary_revision_id]'][value='#{glossary.current_revision_id}']", visible: :all).choose
    assert_selector "[data-workspace-summary-target='terminology']", text: "Japanese Sermon Terms"
    first("#workspace-glossary a", text: "Edit").click
    assert_selector "#workspace-terminology-editor input[name='glossary[entries][][source_term]']", visible: :all
    assert_selector "dialog[open] input[name='glossary[entries][][source_term]']", visible: true
    scroll_to find("#workspace-glossary")
    page.save_screenshot(Rails.root.join("tmp/ux_review/desktop-1440-terminology.png"))
    click_button "Cancel"

    fill_in "Project name", with: "Pasted browser project"
    choose_known_language "Source language", "Vietnamese"
    choose_known_language "Target language", "Japanese"
    fill_in "Document title", with: "Pasted source"
    fill_in "Source text", with: "Pasted text remains supported"
    fill_in "Translation name", with: "Pasted browser experiment"
    fill_in "Instructions for the translation", with: "Translate faithfully."

    assert_enqueued_jobs 1, only: TranslationRunJob do
      click_button "Start translation"
      assert_text "Translation experiment"
      assert_text "Pasted text remains supported"
    end

    assert Document.order(:id).last.pasted_text?
    [ [ 320, 844 ], [ 375, 812 ], [ 768, 1024 ], [ 1024, 800 ], [ 1280, 900 ], [ 1440, 1000 ], [ 1920, 1080 ] ].each do |width, height|
      page.current_window.resize_to(width, height)
      visit new_translation_workspace_path
      assert_selector "h1", text: "New translation"
      if width >= 1024
        assert_selector "aside#app-sidebar", visible: true
        assert_no_selector "button[data-action='sidebar#open']", visible: true
      else
        assert_selector "button[data-action='sidebar#open']", visible: true
      end
      overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
      assert_operator overflow, :<=, 0, "Expected no horizontal overflow at #{width}px, saw #{overflow}px"
      page.save_screenshot(Rails.root.join("tmp/screenshots/responsive-#{width}.png"))
      page.save_screenshot(Rails.root.join("tmp/ux_review/tablet-1024.png")) if width == 1024
      page.save_screenshot(Rails.root.join("tmp/ux_review/mobile-375.png")) if width == 375
    end

    page.current_window.resize_to(320, 844)
    visit new_translation_workspace_path
    find("button[data-action='sidebar#open']").click
    assert_link "Projects"
    page.driver.browser.action.send_keys(:escape).perform
    assert_no_selector "aside#app-sidebar", visible: true
    assert_equal "false", find("button[data-action='sidebar#open']")["aria-expanded"]

    page.current_window.resize_to(1440, 1000)
    visit new_translation_workspace_path
    [ [ 1.25, "125" ], [ 1.5, "150" ], [ 2.0, "200" ] ].each do |scale, label|
      page.driver.browser.execute_cdp(
        "Emulation.setDeviceMetricsOverride",
        width: (1440 / scale).floor,
        height: (1000 / scale).floor,
        deviceScaleFactor: scale,
        mobile: false
      )
      assert_selector "h1", text: "New translation"
      overflow = page.evaluate_script("document.documentElement.scrollWidth - document.documentElement.clientWidth")
      assert_operator overflow, :<=, 0, "Expected no horizontal overflow at #{label}% zoom, saw #{overflow}px"
      if scale < 1.5
        assert_selector "aside#app-sidebar", visible: true
      else
        assert_selector "button[data-action='sidebar#open']", visible: true
      end
      page.save_screenshot(Rails.root.join("tmp/ux_review/zoom-#{label}.png"))
    end
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
    page.current_window.resize_to(1400, 1000)
  end

  def create_browser_glossary
    Glossaries::Create.call(
      user: users(:normal),
      attributes: {
        name: "Japanese Sermon Terms",
        description: "Browser review glossary",
        source_language: "Vietnamese",
        target_language: "Japanese",
        entries: [
          { source_term: "Đức Thánh Linh", preferred_target_term: "聖霊なる神", note: "" },
          { source_term: "Ngôi Lời", preferred_target_term: "御言なる神", note: "" }
        ]
      }
    )
  end

  test "owner edits approves reopens and downloads a final translation without provider work" do
    final_translation = create_final_translation_workspace
    clear_enqueued_jobs
    sign_in_in_browser(users(:normal), "correct horse battery staple")

    visit final_translation_path(final_translation)

    assert_link "Download TXT", href: download_final_translation_path(final_translation, format: :txt)
    assert_link "Download DOCX", href: download_final_translation_path(final_translation, format: :docx)
    fill_in "Final translation draft", with: "Human-edited browser revision"
    fill_in "Change note (optional)", with: "Final human pass"
    click_button "Save revision"

    assert_text "Revision saved."
    assert_field "Final translation draft", with: "Human-edited browser revision"
    assert_text "Version 2"

    accept_confirm(/Finalize version 2 as the approved final translation/) do
      click_button "Finalize current version"
    end
    assert_text "Final translation finalized."
    assert_text "Finalized · read only"
    assert_no_field "Final translation draft"
    assert_link "Download TXT"
    assert_link "Download DOCX"

    accept_confirm(/Reopen this approved translation for editing/) do
      click_button "Reopen for editing"
    end
    assert_text "Final translation reopened for editing."
    assert_field "Final translation draft", with: "Human-edited browser revision"
    assert_no_enqueued_jobs
  end

  private

  def sign_in_in_browser(user, password)
    visit login_path
    fill_in "Email", with: user.email
    fill_in "Password", with: password
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  def failed_experiment_for(user)
    project = Project.create!(
      user: user,
      name: "Browser recovery",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    document = project.documents.create!(title: "Browser source", source_text: "Source")
    experiment = document.experiments.create!(instruction_prompt: "Translate.", status: :running)
    experiment.translation_runs.create!(
      llm_model: llm_models(:openrouter_claude),
      status: :failed,
      error_code: "stale_execution",
      completed_at: Time.current
    )
    TranslationExperiments::ReconcileExperiment.call(experiment)
    experiment
  end
end
