require "test_helper"

class WorkspaceCatalogModelsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = users(:normal)
    sign_in_as @user
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => [ catalog_entry ]) }
  end

  teardown do
    OpenRouter::Catalog.transport = nil
  end

  test "a catalog identifier resolves to a trusted LlmModel and launches without provider work" do
    assert_difference -> { LlmModel.count }, 1 do
      assert_difference -> { TranslationRun.count }, 1 do
        assert_no_difference -> { AiProviderAttempt.count } do
          post translation_workspace_path, params: { translation_workspace: workspace_attributes.merge(model_identifiers: [ catalog_entry["id"] ]) }
        end
      end
    end

    assert_response :redirect
    model = LlmModel.find_by!(model_identifier: catalog_entry["id"])
    assert_equal "vendor", model.provider
    assert_equal "Vendor: Translator Model", model.display_name
    assert_equal 128_000, model.context_window_tokens
    assert_equal 8_192, model.max_output_tokens
  end

  test "a forged identifier is rejected before any record or job is created" do
    assert_no_difference [ -> { LlmModel.count }, -> { TranslationRun.count }, -> { AiProviderAttempt.count } ] do
      assert_no_enqueued_jobs do
        post translation_workspace_path, params: { translation_workspace: workspace_attributes.merge(model_identifiers: [ "../../etc/passwd" ]) }
      end
    end

    assert_response :unprocessable_content
    assert_select "li", text: /AI models include a model that is no longer available/
  end

  test "saved model checkboxes and catalog identifiers can be combined without duplicates" do
    saved = llm_models(:openrouter_claude)

    assert_difference -> { TranslationRun.count }, 2 do
      post translation_workspace_path, params: {
        translation_workspace: workspace_attributes.merge(
          model_ids: [ saved.id.to_s ],
          model_identifiers: [ catalog_entry["id"] ]
        )
      }
    end

    assert_response :redirect
  end

  test "more than the allowed number of models is rejected" do
    count = Ai::UsageLimits::MAX_TRANSLATION_MODELS + 1
    entries = Array.new(count) { |index| catalog_entry.merge("id" => "vendor/model-#{index}") }
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => entries) }

    assert_no_difference -> { TranslationRun.count } do
      post translation_workspace_path, params: {
        translation_workspace: workspace_attributes.merge(model_identifiers: entries.map { |entry| entry["id"] })
      }
    end

    assert_response :unprocessable_content
    assert_select "li", text: /AI models are limited to/
  end

  test "validation and invalid launches do not materialize catalog models" do
    catalog_id = catalog_entry["id"]
    invalid_submissions = [
      workspace_attributes.merge(model_identifiers: []),
      workspace_attributes.merge(model_identifiers: [ "../../etc/passwd" ]),
      workspace_attributes.merge(model_identifiers: [ catalog_id ], document_title: ""),
      workspace_attributes.merge(model_identifiers: [ catalog_id ], instruction_prompt: "")
    ]

    invalid_submissions.each do |attributes|
      assert_no_difference [ -> { LlmModel.count }, -> { AiProviderAttempt.count } ] do
        post translation_workspace_path, params: {
          translation_workspace: attributes.merge(submission_token: issue_translation_workspace_token)
        }
      end
      assert_response :unprocessable_content
    end

    form = TranslationWorkspace.new(
      workspace_attributes.merge(
        document_title: "",
        model_identifiers: [ catalog_id ],
        user: @user
      )
    )
    assert_no_difference [ -> { LlmModel.count }, -> { AiProviderAttempt.count } ] do
      refute form.valid?
    end
  end

  test "seven valid catalog identifiers never materialize model rows" do
    entries = Array.new(7) { |index| catalog_entry.merge("id" => "vendor/bounded-#{index}") }
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => entries) }
    assert_no_difference [ -> { LlmModel.count }, -> { AiProviderAttempt.count } ] do
      post translation_workspace_path, params: {
        translation_workspace: workspace_attributes.merge(
          model_identifiers: entries.map { |entry| entry["id"] }
        )
      }
    end
    assert_response :unprocessable_content
  end

  private

  def workspace_attributes
    {
      project_name: "Catalog project",
      source_language: "Vietnamese",
      target_language: "Japanese",
      document_title: "Catalog source",
      source_text: "Nguồn cho bản dịch.",
      instruction_prompt: "Translate faithfully.",
      submission_token: issue_translation_workspace_token
    }
  end

  def catalog_entry
    {
      "id" => "vendor/translator-model",
      "name" => "Vendor: Translator Model",
      "context_length" => 128_000,
      "architecture" => { "input_modalities" => [ "text" ], "output_modalities" => [ "text" ] },
      "top_provider" => { "max_completion_tokens" => 8_192 },
      "pricing" => { "prompt" => "0.000001", "completion" => "0.000002" },
      "supported_parameters" => [ "max_tokens", "response_format" ]
    }
  end
end
