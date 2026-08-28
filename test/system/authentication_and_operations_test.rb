require "application_system_test_case"

class AuthenticationAndOperationsTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

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

    click_link "Settings / Models"
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
      click_button "Retry failed translations"
      assert_text "Queued 1 failed translation run(s) for retry."
    end
    assert failed_run.reload.pending?
    assert_equal 1, experiment.translation_runs.count
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
