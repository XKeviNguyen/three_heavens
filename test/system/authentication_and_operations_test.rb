require "application_system_test_case"
require "tempfile"
require_relative "../support/final_translation_test_helper"

class AuthenticationAndOperationsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  test "unauthenticated visitor is taken to sign in" do
    visit root_path

    assert_text "Sign in"
    assert_text "Please sign in to continue."
  end

  test "normal user signs in and cannot access admin settings" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")

    assert_text "Start a translation experiment"
    assert_no_link "Settings / Models"
    visit settings_models_path
    assert_text "You are not authorized to access administration settings."
    assert_current_path root_path
  end

  test "admin reaches model settings and operations" do
    sign_in_in_browser(users(:admin), "admin secure password value")

    find("summary", text: /Menu|Admin/).click
    click_link "Settings / Models"
    assert_text "OpenRouter model catalog"
    find("summary", text: /Menu|Admin/).click
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
      accept_confirm(/new provider requests/) do
        click_button "Retry failed translations"
      end
      assert_text "Queued 1 failed translation run(s) for retry."
    end
    assert failed_run.reload.pending?
    assert_equal 1, experiment.translation_runs.count
  end

  test "owner uploads previews edits and consumes a TXT source without AI during preview" do
    sign_in_in_browser(users(:normal), "correct horse battery staple")
    click_link "Upload source file"
    assert_text "Upload a source file"

    source = Tempfile.new([ "browser-source", ".txt" ])
    source.binmode
    source.write("Browser upload\r\n日本語")
    source.flush

    assert_no_enqueued_jobs only: TranslationRunJob do
      attach_file "Source file", source.path
      click_button "Upload and preview"
      assert_text "Uploaded source ready for review"
      assert_field "Reviewed source text", with: "Browser upload\n日本語"
    end

    fill_in "Reviewed source text", with: "Reviewed browser source\n日本語"
    fill_in "Project name", with: "Browser import"
    fill_in "Source language", with: "Vietnamese"
    fill_in "Target language", with: "Japanese"
    fill_in "Document title", with: "Browser source"
    fill_in "Experiment name", with: "Browser secure import"
    fill_in "Translation instruction", with: "Translate faithfully."
    check "translation_workspace_model_ids_#{llm_models(:openrouter_claude).id}"

    assert_enqueued_jobs 1, only: TranslationRunJob do
      click_button "Start translation runs"
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
    fill_in "Project name", with: "Pasted browser project"
    fill_in "Source language", with: "Vietnamese"
    fill_in "Target language", with: "Japanese"
    fill_in "Document title", with: "Pasted source"
    fill_in "Source text", with: "Pasted text remains supported"
    fill_in "Experiment name", with: "Pasted browser experiment"
    fill_in "Translation instruction", with: "Translate faithfully."
    check "translation_workspace_model_ids_#{llm_models(:openrouter_claude).id}"

    assert_enqueued_jobs 1, only: TranslationRunJob do
      click_button "Start translation runs"
      assert_text "Translation experiment"
      assert_text "Pasted text remains supported"
    end

    assert Document.order(:id).last.pasted_text?
    page.current_window.resize_to(320, 844)
    visit projects_path
    assert_selector "summary", text: "Menu"
    find("summary", text: "Menu").click
    assert_link "Projects"
    viewport_width = page.evaluate_script("document.documentElement.clientWidth")
    assert_operator viewport_width, :<=, 500
    assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, viewport_width
    page.current_window.resize_to(1400, 1000)
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
