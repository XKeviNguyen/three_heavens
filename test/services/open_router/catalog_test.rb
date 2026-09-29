require "test_helper"
require "tmpdir"

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

    test "default HTTP transport returns the streamed response body" do
      http = FakeHttp.new('{"data":[]}')

      with_http_class(http) do
        result = OpenRouter::Catalog.new(cache: memory_cache).call

        assert_empty result.models
      end
    end

    test "default HTTP transport rejects a non-success status" do
      http = FakeHttp.new("nope", success: false)

      with_http_class(http) do
        assert_raises(OpenRouter::Catalog::Error) do
          OpenRouter::Catalog.new(cache: memory_cache).call
        end
      end
    end

    FakeResponse = Struct.new(:payload) do
      def is_a?(klass)
        klass == Net::HTTPSuccess
      end

      def decode_content=(_value)
      end

      def read_body
        yield payload
      end
    end

    class FakeHttp
      def initialize(payload, success: true)
        @response = success ? FakeResponse.new(payload) : NonSuccess.new
      end

      def use_ssl=(_value)
      end

      def open_timeout=(_value)
      end

      def read_timeout=(_value)
      end

      def write_timeout=(_value)
      end

      def start
        yield self
      end

      def request(_request)
        yield @response
        @response
      end

      class NonSuccess
        def is_a?(_klass)
          false
        end
      end
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

    test "a failed fetch is not retried upstream until the bounded backoff passes, then recovers" do
      calls = 0
      failing = true
      transport = lambda do
        calls += 1
        raise Net::OpenTimeout, "upstream down" if failing

        JSON.generate("data" => [ model_entry ])
      end
      catalog = OpenRouter::Catalog.new(transport: transport, cache: memory_cache, clock: -> { Time.current })

      5.times { assert_raises(OpenRouter::Catalog::Error) { catalog.call } }
      assert_equal 1, calls, "repeated opens during an outage must not reach upstream again"

      failing = false
      travel OpenRouter::Catalog::FAILURE_BACKOFF + 1.second do
        assert_equal 1, catalog.call.models.size
        assert_equal 2, calls
        catalog.call
        assert_equal 2, calls, "a successful fetch replaces the failure state and is cached"
      end
    end

    test "a later failure after the cache expires starts a new bounded backoff" do
      calls = 0
      failing = false
      transport = lambda do
        calls += 1
        raise Net::ReadTimeout, "upstream down" if failing

        JSON.generate("data" => [ model_entry ])
      end
      catalog = OpenRouter::Catalog.new(transport: transport, cache: memory_cache, clock: -> { Time.current })
      catalog.call

      failing = true
      travel OpenRouter::Catalog::CACHE_TTL + 1.second do
        3.times { assert_raises(OpenRouter::Catalog::Error) { catalog.call } }
        assert_equal 2, calls
      end
    end

    # Production requests read through a request-local cache that memoizes a
    # miss, so waiters must take the leader's outcome rather than re-reading.
    test "concurrent cold requests inside request-local caches share one upstream fetch" do
      Dir.mktmpdir("catalog-cache-") do |directory|
        cache = LocalCachedFileStore.new(directory)
        [ :success, :failure ].each do |outcome|
          cache.clear
          calls = 0
          gate = Queue.new
          transport = lambda do
            calls += 1
            gate.pop
            raise Net::ReadTimeout, "upstream down" if outcome == :failure

            JSON.generate("data" => [ model_entry ])
          end
          threads = 4.times.map do
            Thread.new do
              cache.with_local_cache do
                OpenRouter::Catalog.new(transport:, cache:, clock: -> { Time.current }).call
              rescue OpenRouter::Catalog::Error => error
                error
              end
            end
          end
          sleep 0.05 until calls.positive?
          sleep 0.2
          4.times { gate << true }
          results = threads.map { it.join(10)&.value }

          assert_equal 1, calls, "#{outcome}: waiters must not fetch again"
          if outcome == :success
            assert_equal [ 1 ], results.map { it.models.size }.uniq
          else
            assert results.all?(OpenRouter::Catalog::Error), results.inspect
          end
        end
      end
    end

    # The same composition as SolidCache::Store in production: entries are read
    # through read_serialized_entry with Strategy::LocalCache prepended.
    class LocalCachedFileStore < ActiveSupport::Cache::FileStore
      prepend ActiveSupport::Cache::Strategy::LocalCache
    end

    private

    def with_http_class(fake)
      original = Net::HTTP.method(:new)
      Net::HTTP.define_singleton_method(:new) { |*_arguments| fake }
      yield
    ensure
      Net::HTTP.define_singleton_method(:new, original)
    end

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
