require "test_helper"

class OpenRouterCatalogTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:normal)
    sign_in_as @user
  end

  teardown do
    OpenRouter::Catalog.transport = nil
  end

  test "requires authentication" do
    sign_out
    get open_router_catalog_path

    assert_response :redirect
    assert_match %r{/login}, response.location
  end

  test "returns normalized compatible models and never creates provider attempts" do
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => [ compatible_entry, structured_only_entry, image_entry ]) }

    assert_no_difference -> { AiProviderAttempt.count } do
      get open_router_catalog_path(role: "translator", q: "vendor")

      assert_response :success
      payload = response.parsed_body
      assert_equal "live", payload["source"]
      identifiers = payload["models"].map { |model| model["identifier"] }
      assert_includes identifiers, "vendor/translator-model"
      assert_includes identifiers, "vendor/structured-model"
      refute_includes identifiers, "vendor/image-model"

      structured = payload["models"].find { |model| model["identifier"] == "vendor/structured-model" }
      assert_includes structured["roles"], "judge"
      assert_equal "0.000001", structured["prompt_price"]
      assert_equal false, structured["free"]
    end
  end

  test "filters structured roles and marks free models" do
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => [ compatible_entry, structured_only_entry, free_entry ]) }

    get open_router_catalog_path(role: "judge")

    assert_response :success
    identifiers = response.parsed_body["models"].map { |model| model["identifier"] }
    assert_includes identifiers, "vendor/structured-model"
    refute_includes identifiers, "vendor/translator-model"

    get open_router_catalog_path(role: "translator", q: "free")
    free = response.parsed_body["models"].sole
    assert_equal true, free["free"]
  end

  test "malformed upstream payloads fail safely without leaking provider text" do
    OpenRouter::Catalog.transport = -> { "<html>gateway error sk-or-secret</html>" }

    get open_router_catalog_path

    assert_response :success
    payload = response.parsed_body
    assert_equal "fallback", payload["source"]
    refute_includes response.body, "sk-or"
    refute_includes response.body, "gateway error"
  end

  test "falls back to saved active models when the live catalog is unavailable" do
    OpenRouter::Catalog.transport = -> { raise Net::OpenTimeout, "timed out" }
    saved = llm_models(:openrouter_claude)

    get open_router_catalog_path

    assert_response :success
    payload = response.parsed_body
    assert_equal "fallback", payload["source"]
    assert_includes payload["models"].map { |model| model["identifier"] }, saved.model_identifier
    assert payload["models"].all? { |model| model["source"] == "fallback" }
  end

  test "rejects unsupported roles as translator" do
    OpenRouter::Catalog.transport = -> { JSON.generate("data" => [ compatible_entry ]) }

    get open_router_catalog_path(role: "../admin")

    assert_response :success
    assert_equal "translator", response.parsed_body["role"]
  end

  private

  def compatible_entry
    {
      "id" => "vendor/translator-model",
      "name" => "Vendor: Translator Model",
      "context_length" => 128_000,
      "architecture" => { "input_modalities" => [ "text" ], "output_modalities" => [ "text" ] },
      "top_provider" => { "max_completion_tokens" => 8_192 },
      "pricing" => { "prompt" => "0.000001", "completion" => "0.000002" },
      "supported_parameters" => [ "max_tokens" ]
    }
  end

  def structured_only_entry
    compatible_entry.merge(
      "id" => "vendor/structured-model",
      "name" => "Vendor: Structured Model",
      "supported_parameters" => [ "max_tokens", "response_format" ]
    )
  end

  def image_entry
    compatible_entry.merge(
      "id" => "vendor/image-model",
      "name" => "Vendor: Image Model",
      "architecture" => { "input_modalities" => [ "image" ], "output_modalities" => [ "text" ] }
    )
  end

  def free_entry
    compatible_entry.merge(
      "id" => "vendor/free-model",
      "name" => "Vendor: Free Model",
      "pricing" => { "prompt" => "0", "completion" => "0" }
    )
  end
end
