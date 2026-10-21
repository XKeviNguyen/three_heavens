require "application_system_test_case"

# In the browser: reviewers come from the OpenRouter catalog (structured models
# only), and a failed reviewer is replaced from its card.
class RoleModelSelectionSystemTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:normal)
    visit login_path
    fill_in "Email", with: @user.email
    fill_in "Password", with: "correct horse battery staple"
    click_button "Sign in"
    assert_text "Signed in successfully."
  end

  test "a reviewer that did not translate is picked from the catalog and starts the review" do
    experiment = completed_experiment
    visit experiment_path(experiment)

    within("form[action='#{experiment_review_rounds_path(experiment)}']") do
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add", exact_text: true
      first("button", text: "Add", exact_text: true).click
      assert_text "1 model selected"
      accept_confirm { click_button "Start blind review" }
    end

    assert_text I18n.t("flash_ui.review.started")
    reviewer = experiment.reload.review_round.review_runs.sole.reviewer_llm_model
    structured = OpenRouterCatalogFixture.models.select { |model| model["supported_parameters"].include?("structured_outputs") }
    assert_includes structured.map { |model| model["id"] }, reviewer.model_identifier
    assert_not_includes [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ], reviewer
  end

  test "a failed reviewer is replaced from its card" do
    round = BlindReviews::Start.call(experiment: completed_experiment, reviewer_ids: [ llm_models(:openrouter_gpt).id ])
    clear_enqueued_jobs
    failed = round.review_runs.sole
    failed.update!(status: :failed, error_code: "structured_output_unavailable", error_message: "No OpenRouter provider serves this model with structured output", completed_at: Time.current)
    BlindReviews::ReconcileRound.call(round)

    visit review_round_path(round)
    assert_text I18n.t("results_ui.failure_reasons.structured_output_unavailable")

    # The page guide teaches the replace action where it is shown.
    find("[data-react-island='product-tour'] button[aria-expanded]").click
    find("[data-react-island='product-tour'] li button", text: "Guide to this page").click
    replace_title = I18n.t("product_tour.pages.blind_review.replace.title")
    5.times do
      break if page.has_selector?("[data-testid='product-tour-card'] h2", text: replace_title, wait: 0.5)

      within("[data-testid='product-tour-card']") { click_button "Next", exact_text: true }
    end
    assert_selector "[data-testid='product-tour-card'] h2", text: replace_title
    assert_selector "[data-testid='product-tour-spotlight']", visible: :all
    within("[data-testid='product-tour-card']") { click_button "Skip", exact_text: true }
    assert_no_selector "[data-testid='product-tour']", visible: :all

    within("[data-testid='replace-model']") do
      find("summary").click
      find("input[placeholder='Search OpenRouter models…']").click
      assert_selector "button", text: "Add", exact_text: true
      first("button", text: "Add", exact_text: true).click
      accept_confirm { click_button I18n.t("model_selection.replace_submit.reviewer") }
    end

    # Wait for the page the replacement redirected to, then read the database.
    assert_text "replaced the failed reviewer"
    replacement = failed.reload.superseded_by
    assert replacement, "the failed reviewer was superseded"
    assert_text I18n.t("flash_ui.review.replaced", name: replacement.reviewer_llm_model.display_name)
    assert_selector "[data-testid='replaced-runs']", text: llm_models(:openrouter_gpt).display_name
  end

  private

  def completed_experiment
    project = Project.create!(user: @user, name: "Browser selection #{SecureRandom.hex(3)}",
                              source_language: "Vietnamese", target_language: "Japanese")
    document = project.documents.create!(title: "Source", source_text: "Private source")
    document.experiments.create!(instruction_prompt: "Translate faithfully.", status: :completed).tap do |experiment|
      experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude), status: :completed, translated_text: "First")
      experiment.translation_runs.create!(llm_model: llm_models(:openrouter_gpt), status: :completed, translated_text: "Second")
    end
  end
end
