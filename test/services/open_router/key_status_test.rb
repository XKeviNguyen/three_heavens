require "test_helper"

class OpenRouter::KeyStatusTest < ActiveSupport::TestCase
  KEY = "sk-or-v1-#{"5c" * 32}".freeze

  Response = Data.define(:code, :chunks) do
    def read_body(&block) = chunks.each(&block)
  end

  # Answers GET /api/v1/key with a canned response and records the request.
  class FakeHttp
    attr_reader :requests, :options

    def initialize(code: "200", body: nil, chunks: nil, error: nil)
      @response = Response.new(code: code, chunks: chunks || [ body.to_s ])
      @error = error
      @requests = []
    end

    def start(host, port, **options)
      @options = [ host, port, options ]
      raise @error if @error

      yield self
    end

    def request(request)
      @requests << request
      yield @response
    end
  end

  setup { Rails.cache.clear }

  test "reports a key OpenRouter accepts with its limit, monthly use and free-model allowance" do
    http = FakeHttp.new(body: {
      data: {
        label: "Three_Heavens", limit: 50, limit_remaining: 49.938, usage_monthly: 0.062, is_free_tier: false,
        free_model_daily_requests: { used: 3, limit: 1000, remaining: 997 }
      }
    }.to_json)

    status = OpenRouter::KeyStatus.call(KEY, http: http)

    assert status.valid?
    assert_equal "Three_Heavens", status.label
    assert_equal BigDecimal("50"), status.limit
    assert_equal BigDecimal("49.938"), status.limit_remaining
    assert_equal BigDecimal("0.062"), status.usage_monthly
    assert_equal [ 997, 1000 ], [ status.free_requests_remaining, status.free_requests_limit ]
    assert_equal "Bearer #{KEY}", http.requests.sole["Authorization"]
    assert_equal "/api/v1/key", http.requests.sole.path
    assert_equal [ "openrouter.ai", 443, { use_ssl: true, open_timeout: 3, read_timeout: 4 } ], http.options
  end

  test "a rejected key is invalid; any other failure is only unavailable" do
    assert OpenRouter::KeyStatus.call(KEY, http: FakeHttp.new(code: "401", body: "{}")).invalid?
    assert OpenRouter::KeyStatus.call(KEY, http: FakeHttp.new(code: "403", body: "{}")).invalid?
    assert OpenRouter::KeyStatus.call(KEY, http: FakeHttp.new(code: "500", body: "{}")).unavailable?
    assert OpenRouter::KeyStatus.call(KEY, http: FakeHttp.new(body: "not json")).unavailable?
    assert OpenRouter::KeyStatus.call(KEY, http: FakeHttp.new(error: Net::OpenTimeout.new)).unavailable?
    oversized = FakeHttp.new(chunks: Array.new(3) { "x" * OpenRouter::KeyStatus::MAX_RESPONSE_BYTES })
    assert OpenRouter::KeyStatus.call(KEY, http: oversized).unavailable?
    assert OpenRouter::KeyStatus.call("", http: FakeHttp.new(body: "{}")).unavailable?
  end

  test "caches a result under a digest of the key, never the key" do
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    http = FakeHttp.new(body: { data: { label: "cached", limit: nil } }.to_json)

    2.times { assert OpenRouter::KeyStatus.cached(KEY, http: http).valid? }

    assert_equal 1, http.requests.size
    keys = Rails.cache.instance_variable_get(:@data).keys
    assert keys.any? { |key| key.include?(Digest::SHA256.hexdigest(KEY)) }
    assert keys.none? { |key| key.include?(KEY) }
  ensure
    Rails.cache = original
  end
end
