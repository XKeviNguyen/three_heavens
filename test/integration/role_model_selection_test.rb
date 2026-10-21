require "test_helper"
require_relative "../support/judging_test_helper"

# Reviewers, judges and refiners are searched in the OpenRouter catalog, and
# the server refuses a model that cannot return structured answers. A failed
# reviewer or judge can be replaced in place, billed to the payer shown.
class RoleModelSelectionTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include JudgingTestHelper

  STRUCTURED = "vendor/structured-reviewer".freeze
  JSON_MODE_ONLY = "vendor/json-mode-only".freeze

  setup do
    @current_test_user = users(:normal)
    sign_in_as @current_test_user
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => [ entry(STRUCTURED, structured: true), entry(JSON_MODE_ONLY, structured: false) ]) }
  end

  teardown { OpenRouter::Catalog.transport = nil }

  test "reviewers can be any structured model from the catalog; a JSON-mode-only model is refused" do
    experiment = completed_experiment

    post experiment_review_rounds_path(experiment), params: { review_round: { reviewer_identifiers: [ JSON_MODE_ONLY ] } }
    assert_response :unprocessable_content
    assert_includes CGI.unescapeHTML(response.body), I18n.t("model_selection.incompatible", role: I18n.t("model_selection.roles.reviewer"))
    assert_nil experiment.reload.review_round

    assert_enqueued_jobs 1, only: ReviewRunJob do
      post experiment_review_rounds_path(experiment), params: { review_round: { reviewer_identifiers: [ STRUCTURED ] } }
    end
    round = experiment.reload.review_round
    assert_redirected_to review_round_path(round)
    assert_equal [ STRUCTURED ], round.review_runs.map { |run| run.reviewer_llm_model.model_identifier }
  end

  test "a saved model the catalog marks incapable is refused too" do
    experiment = completed_experiment
    json_mode = LlmModel.create!(gateway: "openrouter", provider: "vendor", model_identifier: JSON_MODE_ONLY, display_name: "JSON mode only")

    post experiment_review_rounds_path(experiment), params: { review_round: { reviewer_ids: [ json_mode.id ] } }

    assert_response :unprocessable_content
    assert_nil experiment.reload.review_round
  end

  test "a failed reviewer is replaced from its card under the payer shown, and the history says so" do
    round, failed = failed_review_round
    get review_round_path(round)
    assert_select "[data-testid='replace-model'] [data-model-browser-role-value='reviewer']", count: 1
    payer = Ai::BillingPolicy.authorize!(@current_test_user)
    params = { review_run_id: failed.id, replacement: { identifiers: [ STRUCTURED ] },
               billing_source: payer.billing_source, billing_key: payer.open_router_credential_id.to_s }

    post replace_reviewer_review_round_path(round), params: params.merge(billing_source: "personal")
    assert_redirected_to review_round_path(round)
    assert_equal I18n.t("ai_billing.retry_payer_changed"), flash[:alert]
    assert_nil failed.reload.superseded_by_id

    assert_enqueued_jobs 1, only: ReviewRunJob do
      post replace_reviewer_review_round_path(round), params: params
    end
    assert_redirected_to review_round_path(round)
    replacement = failed.reload.superseded_by
    assert_equal STRUCTURED, replacement.reviewer_llm_model.model_identifier
    assert round.reload.running?

    get review_round_path(round)
    assert_select "[data-testid='replaced-runs']", text: /#{Regexp.escape(failed.reviewer_llm_model.display_name)}/
  end

  test "replacing with a model that cannot review is refused without changes" do
    round, failed = failed_review_round
    payer = Ai::BillingPolicy.authorize!(@current_test_user)

    assert_no_enqueued_jobs do
      post replace_reviewer_review_round_path(round), params: {
        review_run_id: failed.id, replacement: { identifiers: [ JSON_MODE_ONLY ] },
        billing_source: payer.billing_source, billing_key: payer.open_router_credential_id.to_s
      }
    end
    assert_redirected_to review_round_path(round)
    assert_match(/cannot work as a reviewer/, flash[:alert])
    assert_nil failed.reload.superseded_by_id
  end

  test "when the catalog is down, a saved model offered by the browser can still replace a failed reviewer" do
    round, failed = failed_review_round
    payer = Ai::BillingPolicy.authorize!(@current_test_user)
    billing = { billing_source: payer.billing_source, billing_key: payer.open_router_credential_id.to_s }
    saved = LlmModel.create!(gateway: "openrouter", provider: "vendor", model_identifier: "vendor/saved-#{SecureRandom.hex(2)}", display_name: "Saved reviewer")
    OpenRouter::Catalog.transport = -> { raise OpenRouter::Catalog::Error, "catalog down" }

    post replace_reviewer_review_round_path(round), params: billing.merge(review_run_id: failed.id, replacement: "not-a-hash")
    assert_redirected_to review_round_path(round)
    assert_equal I18n.t("model_selection.choose_one"), flash[:alert]

    assert_enqueued_jobs 1, only: ReviewRunJob do
      post replace_reviewer_review_round_path(round), params: billing.merge(review_run_id: failed.id, replacement: { ids: [ saved.id ] })
    end
    assert_redirected_to review_round_path(round)
    assert_equal saved, failed.reload.superseded_by.reviewer_llm_model
  end

  private

  def entry(identifier, structured:)
    {
      "id" => identifier, "name" => "Vendor: #{identifier.split("/").last}", "context_length" => 128_000,
      "architecture" => { "input_modalities" => [ "text" ], "output_modalities" => [ "text" ] },
      "top_provider" => { "max_completion_tokens" => 8_192 },
      "pricing" => { "prompt" => "0.000001", "completion" => "0.000002" },
      "supported_parameters" => structured ? %w[max_tokens response_format structured_outputs] : %w[max_tokens response_format]
    }
  end

  def completed_experiment
    project = Project.create!(user: @current_test_user, name: "Selection #{SecureRandom.hex(3)}",
                              source_language: "Vietnamese", target_language: "Japanese")
    document = project.documents.create!(title: "Source", source_text: "Private source")
    document.experiments.create!(instruction_prompt: "Translate faithfully.", status: :completed).tap do |experiment|
      experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude), status: :completed, translated_text: "First")
      experiment.translation_runs.create!(llm_model: llm_models(:openrouter_gpt), status: :completed, translated_text: "Second")
    end
  end

  def failed_review_round
    round = BlindReviews::Start.call(experiment: completed_experiment, reviewer_ids: [ llm_models(:openrouter_gpt).id ])
    clear_enqueued_jobs
    failed = round.review_runs.first
    failed.update!(status: :failed, error_code: "structured_output_unavailable", completed_at: Time.current)
    BlindReviews::ReconcileRound.call(round)
    [ round.reload, failed ]
  end
end
