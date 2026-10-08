require "test_helper"
require_relative "../support/analytics_test_helper"
require_relative "../support/final_translation_test_helper"

class SettingsModelsTest < ActionDispatch::IntegrationTest
  include AnalyticsTestHelper
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @current_test_user = users(:admin)
    sign_in_as @current_test_user
  end

  test "admin can select an active saved outage model without catalog access or activation" do
    model = llm_models(:openrouter_claude)
    original_transport = OpenRouter::Catalog.transport
    OpenRouter::Catalog.transport = -> { flunk "saved selection must not fetch the catalog" }
    assert_no_difference -> { LlmModel.count } do
      post catalog_settings_models_path, params: { model_id: model.id.to_s }
    end
    assert_redirected_to settings_models_path
    assert model.reload.active?
  ensure
    OpenRouter::Catalog.transport = original_transport
  end

  test "saved admin catalog selections reject inactive IDs malformed IDs and mixed contracts" do
    model = llm_models(:openrouter_claude)
    model.update!(active: false)
    post catalog_settings_models_path, params: { model_id: model.id.to_s }
    assert_response :not_found
    refute model.reload.active?
    [ { model_id: "#{model.id}oops" }, { model_id: [ model.id.to_s ] },
      { model_id: model.id.to_s, model_identifier: model.model_identifier } ].each do |selection|
      post catalog_settings_models_path, params: selection
      assert_response :bad_request
    end
    sign_out
    sign_in_as users(:normal)
    post catalog_settings_models_path, params: { model_id: llm_models(:openrouter_gpt).id.to_s }
    assert_redirected_to root_path
  end

  test "catalog lists model metadata usage actions and only valid benchmark links" do
    used_model = llm_models(:openrouter_claude)
    unused_model = create_model("unused-list")
    review_round = experiments(:one).create_review_round!(status: :running)
    review_round.review_runs.create!(reviewer_llm_model: used_model)
    judge_round = review_round.create_judge_round!(status: :running)
    judge_round.judge_runs.create!(judge_llm_model: used_model)

    get settings_models_path

    assert_response :success
    assert_select "h1", "OpenRouter model catalog"
    assert_select "a[href='#{settings_models_path}']", "Models"
    assert_select "tr[data-model-id='#{used_model.id}']", text: /Translations:\s*1/m
    assert_select "tr[data-model-id='#{used_model.id}']", text: /Reviews as reviewer:\s*1/m
    assert_select "tr[data-model-id='#{used_model.id}']", text: /Judgments as judge:\s*1/m
    assert_select "tr[data-model-id='#{used_model.id}']", text: /Finalizations as finalizer:\s*0/m
    assert_select "tr[data-model-id='#{used_model.id}'] a[href='#{benchmark_model_path(used_model)}']", "Benchmark"
    assert_select "tr[data-model-id='#{unused_model.id}'] a[href='#{benchmark_model_path(unused_model)}']", count: 0
    assert_select "a", text: "Delete", count: 0
    assert_select "form[action='#{deactivate_settings_model_path(used_model)}']"
  end

  test "inactive finalizer-only model visibly reports history and keeps identifier immutable" do
    final_translation = create_final_translation_workspace
    finalizer = create_model("finalizer-only-usage")
    round = final_translation.finalization_rounds.create!(
      base_version: final_translation.current_version,
      selection_key: "f" * 64
    )
    complete_finalization_run(
      round.finalization_runs.create!(finalizer_llm_model: finalizer)
    )
    finalizer.update!(active: false)

    get settings_models_path

    assert_response :success
    assert_select "tr[data-model-id='#{finalizer.id}']", text: /Inactive/
    assert_select "tr[data-model-id='#{finalizer.id}']", text: /Translations:\s*0/m
    assert_select "tr[data-model-id='#{finalizer.id}']", text: /Reviews as reviewer:\s*0/m
    assert_select "tr[data-model-id='#{finalizer.id}']", text: /Judgments as judge:\s*0/m
    assert_select "tr[data-model-id='#{finalizer.id}']", text: /Finalizations as finalizer:\s*1/m

    patch settings_model_path(finalizer), params: {
      llm_model: { model_identifier: "test/finalizer-history-rewrite" }
    }

    assert_response :unprocessable_content
    assert_select "li", text: /Model identifier cannot be changed after the model has historical usage/
    assert_equal "test/finalizer-only-usage", finalizer.reload.model_identifier
  end

  test "catalog Add explicitly reactivates an inactive historical model without duplication" do
    model = llm_models(:openrouter_claude)
    model.update!(active: false)
    entry = {
      "id" => model.model_identifier,
      "name" => model.display_name,
      "context_length" => 128_000,
      "architecture" => { "input_modalities" => [ "text" ], "output_modalities" => [ "text" ] },
      "top_provider" => { "max_completion_tokens" => 8_192 },
      "pricing" => { "prompt" => "0.000001", "completion" => "0.000002" },
      "supported_parameters" => [ "max_tokens", "response_format" ]
    }
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => [ entry ]) }

    assert_no_difference -> { LlmModel.count } do
      post catalog_settings_models_path, params: { model_identifier: model.model_identifier }
    end

    assert_redirected_to settings_models_path
    assert model.reload.active?
    assert_match(/activated/, flash[:notice])
  ensure
    OpenRouter::Catalog.transport = nil
  end

  test "creates a trimmed active OpenRouter model" do
    assert_difference -> { LlmModel.count }, 1 do
      post settings_models_path,
           params: {
             llm_model: {
               provider: "  anthropic  ",
               model_identifier: "  anthropic/claude-created  ",
               display_name: "  Claude Created  ",
               context_window_tokens: "128000",
               max_output_tokens: "8192"
             }
           }
    end

    model = LlmModel.order(:id).last
    assert_redirected_to settings_models_path
    assert_equal "openrouter", model.gateway
    assert_equal "anthropic", model.provider
    assert_equal "anthropic/claude-created", model.model_identifier
    assert_equal "Claude Created", model.display_name
    assert_equal 128_000, model.context_window_tokens
    assert_equal 8_192, model.max_output_tokens
    assert model.active?
  end

  test "renders validation errors for blank duplicate and malformed metadata" do
    existing = llm_models(:openrouter_claude)

    assert_no_difference -> { LlmModel.count } do
      post settings_models_path,
           params: {
             llm_model: {
               provider: "",
               model_identifier: existing.model_identifier,
               display_name: ""
             }
           }
    end

    assert_response :unprocessable_content
    assert_select "li", text: /Provider can't be blank/
    assert_select "li", text: /Model identifier has already been taken/
    assert_select "li", text: /Display name can't be blank/

    assert_no_difference -> { LlmModel.count } do
      post settings_models_path,
           params: {
             llm_model: {
               provider: "anthropic",
               model_identifier: "https://credential@example.com/model?token=value",
               display_name: "Malformed"
             }
           }
    end
    assert_response :unprocessable_content
    assert_select "li", text: /Model identifier must be an OpenRouter identifier/
  end

  test "rejects unsupported and mass-assigned attributes" do
    assert_no_difference -> { LlmModel.count } do
      post settings_models_path,
           params: {
             llm_model: {
               gateway: "direct",
               active: false,
               provider: "anthropic",
               model_identifier: "anthropic/tampered",
               display_name: "Tampered"
             }
           }
    end

    assert_response :bad_request
  end

  test "rejects missing model parameters without creating a model" do
    assert_no_difference -> { LlmModel.count } do
      post settings_models_path, params: {}
    end

    assert_response :bad_request
  end

  test "rejects scalar model parameters without creating or modifying a model" do
    assert_malformed_model_payload_rejected("malformed", suffix: "scalar-shape")
  end

  test "rejects array model parameters without creating or modifying a model" do
    assert_malformed_model_payload_rejected([ "malformed" ], suffix: "array-shape")
  end

  test "updates safe metadata and an unused identifier" do
    model = create_model("unused-edit")

    patch settings_model_path(model),
          params: {
            llm_model: {
              provider: " Updated provider ",
              model_identifier: " updated/identifier ",
              display_name: " Updated name "
            }
          }

    assert_redirected_to settings_models_path
    model.reload
    assert_equal "Updated provider", model.provider
    assert_equal "updated/identifier", model.model_identifier
    assert_equal "Updated name", model.display_name
  end

  test "rejects a historical identifier change while allowing its safe metadata form" do
    model = llm_models(:openrouter_claude)

    patch settings_model_path(model),
          params: {
            llm_model: {
              provider: "New provider",
              model_identifier: "anthropic/history-rewrite",
              display_name: "New name"
            }
          }

    assert_response :unprocessable_content
    assert_select "li", text: /Model identifier cannot be changed after the model has historical usage/
    assert_equal "anthropic/claude-test", model.reload.model_identifier
    assert_not_equal "New provider", model.provider

    patch settings_model_path(model),
          params: {
            llm_model: {
              provider: "New provider",
              display_name: "New name"
            }
          }

    assert_redirected_to settings_models_path
    assert_equal "New provider", model.reload.provider
    assert_equal "New name", model.display_name
  end

  test "explicit actions deactivate and reactivate without altering history" do
    model = llm_models(:openrouter_claude)
    translation_run_ids = model.translation_run_ids

    patch deactivate_settings_model_path(model),
          params: { llm_model: { active: true, display_name: "Tampered name" } }

    assert_redirected_to settings_models_path
    model.reload
    assert_not model.active?
    assert_equal "Claude Test", model.display_name
    assert_equal translation_run_ids, model.translation_run_ids

    get new_translation_workspace_path
    assert_select "input[type='checkbox'][value='#{model.id}']", count: 0

    patch activate_settings_model_path(model), params: { active: false }

    assert_redirected_to settings_models_path
    assert model.reload.active?
    assert_equal translation_run_ids, model.translation_run_ids
  end

  test "deactivation removes a historical model from every future selector but not analytics" do
    model = create_model("deactivation-regression")
    opponent = create_model("deactivation-opponent")
    historical_experiment, historical_runs = create_analytics_experiment(
      name: "Historical model usage",
      models: [ model, opponent ]
    )
    historical_review_round = create_review_round_with_runs(
      experiment: historical_experiment,
      specs: [
        {
          reviewer: model,
          scores: { historical_runs[model] => 9, historical_runs[opponent] => 7 }
        }
      ]
    )
    create_judge_round_with_runs(
      review_round: historical_review_round,
      specs: [
        {
          judge: model,
          scores: { historical_runs[model] => 90, historical_runs[opponent] => 70 }
        }
      ],
      winner: historical_runs[model]
    )
    reviewer_experiment, = create_analytics_experiment(
      name: "Eligible reviewer selection",
      models: [ model, opponent ]
    )
    judge_experiment, judge_candidates = create_analytics_experiment(
      name: "Eligible judge selection",
      models: [ model, opponent ]
    )
    judge_selection_review_round = create_review_round_with_runs(
      experiment: judge_experiment,
      specs: [
        {
          reviewer: opponent,
          scores: { judge_candidates[model] => 8, judge_candidates[opponent] => 7 }
        }
      ]
    )
    historical_ids = {
      translations: model.translation_run_ids.sort,
      reviews: model.review_run_ids.sort,
      judges: model.judge_run_ids.sort
    }

    assert_model_is_available_in_all_selectors(
      model,
      reviewer_experiment: reviewer_experiment,
      judge_review_round: judge_selection_review_round
    )

    patch deactivate_settings_model_path(model)

    assert_redirected_to settings_models_path
    assert_not model.reload.active?

    get new_translation_workspace_path
    assert_select "input[name='translation_workspace[model_ids][]'][value='#{model.id}']", count: 0

    get experiment_path(reviewer_experiment)
    assert_select "h2", "Start blind review"
    assert_select "input[name='review_round[reviewer_ids][]'][value='#{model.id}']", count: 0

    get review_round_path(judge_selection_review_round)
    assert_select "h2", "Start judging"
    assert_select "input[name='judge_round[judge_ids][]'][value='#{model.id}']", count: 0

    assert_equal historical_ids[:translations], model.translation_run_ids.sort
    assert_equal historical_ids[:reviews], model.review_run_ids.sort
    assert_equal historical_ids[:judges], model.judge_run_ids.sort

    get benchmarks_path
    assert_response :success
    assert_select "article[data-model-id='#{model.id}']", text: /Inactive/
  end

  test "does not expose non-OpenRouter records through the settings area" do
    direct_model = LlmModel.create!(
      gateway: "direct",
      provider: "anthropic",
      model_identifier: "anthropic/direct-settings-test",
      display_name: "Direct settings test"
    )

    get settings_models_path
    assert_select "tr[data-model-id='#{direct_model.id}']", count: 0

    get edit_settings_model_path(direct_model)
    assert_response :not_found
  end

  private

  def assert_malformed_model_payload_rejected(payload, suffix:)
    model = create_model(suffix)
    original_attributes = model.attributes

    assert_no_difference -> { LlmModel.count } do
      post settings_models_path, params: { llm_model: payload }
    end
    assert_response :bad_request

    patch settings_model_path(model), params: { llm_model: payload }

    assert_response :bad_request
    assert_equal original_attributes, model.reload.attributes
  end

  def assert_model_is_available_in_all_selectors(model, reviewer_experiment:, judge_review_round:)
    get new_translation_workspace_path
    assert_select "#workspace-manual-models input[name='translation_workspace[model_ids][]'][value='#{model.id}']", count: 0
    assert_select "#workspace-manual-models[data-available='true']", count: 1

    get experiment_path(reviewer_experiment)
    assert_select "h2", "Start blind review"
    assert_select "input[name='review_round[reviewer_ids][]'][value='#{model.id}']", count: 1

    get review_round_path(judge_review_round)
    assert_select "h2", "Start judging"
    assert_select "input[name='judge_round[judge_ids][]'][value='#{model.id}']", count: 1
  end

  def create_model(suffix)
    LlmModel.create!(
      gateway: "openrouter",
      provider: "test-provider",
      model_identifier: "test/#{suffix}",
      display_name: "Test #{suffix}"
    )
  end
end
