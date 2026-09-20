require "test_helper"

module OpenRouter
  class CatalogTest < ActiveSupport::TestCase
    def teardown
      OpenRouter::Catalog.transport = nil
    end

    test "endpoint is fixed HTTPS and never accepts an arbitrary URL" do
      assert_equal "openrouter.ai", OpenRouter::Catalog::ENDPOINT.host
      assert_equal "/api/v1/models", OpenRouter::Catalog::ENDPOINT.path
      assert_equal "https", OpenRouter::Catalog::ENDPOINT.scheme
    end

    test "normalizes allowlisted catalog metadata" do
      result = build_catalog(model_entry).call

      model = result.models.sole
      assert_equal "anthropic/claude-3.5-haiku", model.identifier
      assert_equal "anthropic", model.provider
      assert_equal "Anthropic: Claude 3.5 Haiku", model.name
      assert_equal 200_000, model.context_length
      assert_equal 8_192, model.max_completion_tokens
      assert_equal BigDecimal("0.0000008"), model.prompt_price
      assert_equal BigDecimal("0.000004"), model.completion_price
      assert_includes model.input_modalities, "text"
      assert_includes model.output_modalities, "text"
      assert model.translation_capable?
      assert model.structured_capable?
      refute model.free?
    end

    test "rejects malformed JSON" do
      catalog = OpenRouter::Catalog.new(transport: -> { "not-json" }, cache: memory_cache)

      assert_raises(OpenRouter::Catalog::Error) { catalog.call }
    end

    test "rejects a malformed payload shape" do
      catalog = OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => "nope") }, cache: memory_cache)

      assert_raises(OpenRouter::Catalog::Error) { catalog.call }
    end

    test "rejects oversized catalogs" do
      entries = Array.new(OpenRouter::Catalog::MAX_MODELS + 1) { model_entry }
      catalog = OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => entries) }, cache: memory_cache)

      assert_raises(OpenRouter::Catalog::Error) { catalog.call }
    end

    test "network failures and timeouts raise a safe generic error" do
      catalog = OpenRouter::Catalog.new(
        transport: -> { raise Net::ReadTimeout, "timeout for sk-or-secret-value" },
        cache: memory_cache
      )

      error = assert_raises(OpenRouter::Catalog::Error) { catalog.call }
      assert_equal "The OpenRouter model catalog is unavailable.", error.message
      refute_includes error.message, "sk-or"
    end

    test "drops malformed identifiers and normalizes pricing safely" do
      entries = [
        model_entry,
        model_entry.merge("id" => "not-a-valid-identifier"),
        model_entry.merge("id" => "vendor/model", "pricing" => { "prompt" => "oops", "completion" => "0" })
      ]
      result = OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => entries) }, cache: memory_cache).call

      assert_equal 2, result.models.size
      unpriced = result.models.find { |model| model.identifier == "vendor/model" }
      assert_nil unpriced.prompt_price
      assert_equal BigDecimal("0"), unpriced.completion_price
      refute unpriced.free?
    end

    test "classifies text-only and structured compatibility" do
      text_only = OpenRouter::Catalog::Model.new(
        identifier: "vendor/text-only",
        name: "Text only",
        provider: "vendor",
        context_length: 32_000,
        max_completion_tokens: 8_192,
        prompt_price: BigDecimal("0"),
        completion_price: BigDecimal("0"),
        input_modalities: [ "text" ],
        output_modalities: [ "text" ],
        supported_parameters: [ "max_tokens" ]
      )
      assert text_only.translation_capable?
      refute text_only.structured_capable?
      assert_equal [ "translator" ], text_only.roles
      assert text_only.free?

      image_only = OpenRouter::Catalog::Model.new(
        identifier: "vendor/image",
        name: "Image",
        provider: "vendor",
        context_length: 32_000,
        max_completion_tokens: 8_192,
        prompt_price: BigDecimal("0"),
        completion_price: BigDecimal("0"),
        input_modalities: [ "image" ],
        output_modalities: [ "text" ],
        supported_parameters: [ "response_format" ]
      )
      refute image_only.translation_capable?
      assert_empty image_only.roles
    end

    test "uses the injected cache for the TTL window" do
      calls = 0
      cache = memory_cache
      transport = lambda do
        calls += 1
        JSON.generate("data" => [ model_entry ])
      end
      catalog = OpenRouter::Catalog.new(transport: transport, cache: cache, clock: -> { Time.current })

      2.times { catalog.call }

      assert_equal 1, calls
      cached = cache.read(OpenRouter::Catalog::CACHE_KEY)
      assert_instance_of OpenRouter::Catalog::Result, cached
      assert_equal 1, cached.models.size
    end

    private

    def memory_cache
      ActiveSupport::Cache::MemoryStore.new
    end

    def build_catalog(entry)
      OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => [ entry ]) }, cache: memory_cache)
    end

    def model_entry
      {
        "id" => "anthropic/claude-3.5-haiku",
        "name" => "Anthropic: Claude 3.5 Haiku",
        "context_length" => 200_000,
        "architecture" => {
          "input_modalities" => [ "text", "image" ],
          "output_modalities" => [ "text" ]
        },
        "top_provider" => { "max_completion_tokens" => 8_192 },
        "pricing" => { "prompt" => "0.0000008", "completion" => "0.000004" },
        "supported_parameters" => [ "max_tokens", "response_format", "structured_outputs" ]
      }
    end
  end
end
