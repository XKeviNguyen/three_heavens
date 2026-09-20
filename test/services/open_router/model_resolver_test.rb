require "test_helper"

module OpenRouter
  class ModelResolverTest < ActiveSupport::TestCase
    def teardown
      OpenRouter::Catalog.transport = nil
    end

    test "creates a persisted model from canonical catalog metadata" do
      model = OpenRouter::ModelResolver.call(identifier: "vendor/new-model", catalog: catalog)

      assert model.persisted?
      assert model.active?
      assert_equal "openrouter", model.gateway
      assert_equal "vendor", model.provider
      assert_equal "Vendor: New Model", model.display_name
      assert_equal 64_000, model.context_window_tokens
      assert_equal 8_192, model.max_output_tokens
    end

    test "reuses existing model identity instead of duplicating" do
      existing = llm_models(:openrouter_claude)

      assert_no_difference -> { LlmModel.count } do
        resolved = OpenRouter::ModelResolver.call(identifier: existing.model_identifier, catalog: catalog)
        assert_equal existing.id, resolved.id
      end
    end

    test "rejects inactive persisted models" do
      existing = llm_models(:openrouter_claude)
      existing.update!(active: false)

      assert_raises(OpenRouter::ModelResolver::InactiveModelError) do
        OpenRouter::ModelResolver.call(identifier: existing.model_identifier, catalog: catalog)
      end
    end

    test "rejects unknown and malformed identifiers" do
      assert_raises(OpenRouter::ModelResolver::UnknownModelError) do
        OpenRouter::ModelResolver.call(identifier: "vendor/does-not-exist", catalog: catalog)
      end
      assert_raises(OpenRouter::ModelResolver::UnknownModelError) do
        OpenRouter::ModelResolver.call(identifier: "../../etc/passwd", catalog: catalog)
      end
      assert_raises(OpenRouter::ModelResolver::UnknownModelError) do
        OpenRouter::ModelResolver.call(identifier: "no-slash", catalog: catalog)
      end
    end

    test "structured roles require structured-output capability" do
      assert_raises(OpenRouter::ModelResolver::IncompatibleModelError) do
        OpenRouter::ModelResolver.call(identifier: "vendor/text-only", role: "judge", catalog: catalog)
      end
    end

    test "translator role accepts a text model without structured output" do
      model = OpenRouter::ModelResolver.call(identifier: "vendor/text-only", role: "translator", catalog: catalog)

      assert_equal "vendor", model.provider
    end

    private

    def catalog
      entries = [
        entry("vendor/new-model", "Vendor: New Model", context_length: 64_000, max_output: 8_192, supported: %w[max_tokens response_format]),
        entry("vendor/text-only", "Vendor: Text Only", context_length: 32_000, max_output: 4_096, supported: %w[max_tokens]),
        entry(llm_models(:openrouter_claude).model_identifier, "Anthropic: Claude Test", context_length: 200_000, max_output: 8_192, supported: %w[max_tokens response_format])
      ]
      OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => entries) }, cache: ActiveSupport::Cache::MemoryStore.new)
    end

    def entry(identifier, name, context_length:, max_output:, supported:)
      {
        "id" => identifier,
        "name" => name,
        "context_length" => context_length,
        "architecture" => {
          "input_modalities" => [ "text" ],
          "output_modalities" => [ "text" ]
        },
        "top_provider" => { "max_completion_tokens" => max_output },
        "pricing" => { "prompt" => "0.000001", "completion" => "0.000002" },
        "supported_parameters" => supported
      }
    end
  end
end
