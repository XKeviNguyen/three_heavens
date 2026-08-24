require "test_helper"

class Ai::OpenRouterClientTest < ActiveSupport::TestCase
  FakeResponse = Data.define(:code, :body)

  class FakeHttp
    attr_accessor :use_ssl,
                  :open_timeout,
                  :read_timeout,
                  :write_timeout
    attr_reader :last_request

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
    end

    def start
      yield self
    end

    def request(request)
      @last_request = request
      raise @error if @error

      @response
    end
  end

  setup do
    @original_api_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "test-openrouter-key"
  end

  teardown do
    if @original_api_key
      ENV["OPENROUTER_API_KEY"] = @original_api_key
    else
      ENV.delete("OPENROUTER_API_KEY")
    end
  end

  test "sends authenticated role-separated messages and parses telemetry" do
    http = fake_http(
      status: 200,
      body: {
        id: "generation-123",
        model: "anthropic/claude-resolved",
        choices: [ { message: { content: "Translated text" } } ],
        usage: {
          prompt_tokens: 120,
          completion_tokens: 45,
          total_tokens: 165,
          cost: "0.0012345678",
          prompt_tokens_details: { cached_tokens: 20 },
          completion_tokens_details: { reasoning_tokens: 8 }
        }
      }
    )
    client = build_client(http)

    result = client.chat_completion(
      model_identifier: "anthropic/claude-requested",
      instruction_prompt: "Translate from Vietnamese to Japanese.",
      source_text: "Source theological text"
    )

    assert_equal "Bearer test-openrouter-key", http.last_request["Authorization"]
    assert_equal "application/json", http.last_request["Content-Type"]
    assert_equal true, http.use_ssl
    assert_equal 5, http.open_timeout
    assert_equal 60, http.read_timeout
    assert_equal 10, http.write_timeout

    payload = JSON.parse(http.last_request.body)
    assert_equal "anthropic/claude-requested", payload["model"]
    assert_equal({ "include" => true }, payload["usage"])
    assert_equal(
      [
        {
          "role" => "system",
          "content" => "Translate from Vietnamese to Japanese."
        },
        { "role" => "user", "content" => "Source theological text" }
      ],
      payload["messages"]
    )

    assert_equal "Translated text", result.content
    assert_equal "generation-123", result.provider_response_id
    assert_equal "anthropic/claude-resolved", result.resolved_model_identifier
    assert_equal 120, result.prompt_tokens
    assert_equal 45, result.completion_tokens
    assert_equal 165, result.total_tokens
    assert_equal 20, result.cached_tokens
    assert_equal 8, result.reasoning_tokens
    assert_equal BigDecimal("0.0012345678"), result.cost
  end

  test "classifies rate limits and server errors as retryable" do
    [ 429, 500, 503 ].each do |status|
      client = build_client(
        fake_http(
          status: status,
          body: { error: { code: "provider_busy", message: "Try again" } }
        )
      )

      error = assert_raises Ai::OpenRouterClient::RetryableError do
        client.chat_completion(**request_attributes)
      end

      assert_equal "provider_busy", error.code
    end
  end

  test "classifies other client errors as permanent and sanitizes secrets" do
    client = build_client(
      fake_http(
        status: 400,
        body: {
          error: {
            code: "invalid_request",
            message: "Bad key test-openrouter-key Bearer another-secret"
          }
        }
      )
    )

    error = assert_raises Ai::OpenRouterClient::PermanentError do
      client.chat_completion(**request_attributes)
    end

    assert_equal "invalid_request", error.code
    assert_not_includes error.message, "test-openrouter-key"
    assert_not_includes error.message, "another-secret"
    assert_includes error.message, "[FILTERED]"
  end

  test "classifies network errors as retryable without exposing details" do
    http = FakeHttp.new(error: Net::ReadTimeout.new("private response body"))
    client = build_client(http)

    error = assert_raises Ai::OpenRouterClient::RetryableError do
      client.chat_completion(**request_attributes)
    end

    assert_equal "network_error", error.code
    assert_not_includes error.message, "private response body"
  end

  test "handles malformed success JSON as retryable" do
    response = FakeResponse.new(code: "200", body: "not-json")
    client = build_client(FakeHttp.new(response: response))

    error = assert_raises Ai::OpenRouterClient::RetryableError do
      client.chat_completion(**request_attributes)
    end

    assert_equal "malformed_json", error.code
  end

  test "handles malformed rate-limit and server responses as retryable" do
    [ 429, 503 ].each do |status|
      response = FakeResponse.new(code: status.to_s, body: "not-json")
      client = build_client(FakeHttp.new(response: response))

      error = assert_raises Ai::OpenRouterClient::RetryableError do
        client.chat_completion(**request_attributes)
      end

      assert_equal "malformed_json", error.code
    end
  end

  test "handles malformed normal client-error responses as permanent" do
    response = FakeResponse.new(code: "400", body: "not-json")
    client = build_client(FakeHttp.new(response: response))

    error = assert_raises Ai::OpenRouterClient::PermanentError do
      client.chat_completion(**request_attributes)
    end

    assert_equal "malformed_json", error.code
  end

  test "fails permanently when the API key is missing" do
    ENV.delete("OPENROUTER_API_KEY")

    error = assert_raises Ai::OpenRouterClient::PermanentError do
      Ai::OpenRouterClient.new
    end

    assert_equal "missing_api_key", error.code
  end

  private

  def fake_http(status:, body:)
    FakeHttp.new(
      response: FakeResponse.new(code: status.to_s, body: JSON.generate(body))
    )
  end

  def build_client(http)
    Ai::OpenRouterClient.new(http_factory: ->(_uri) { http })
  end

  def request_attributes
    {
      model_identifier: "anthropic/claude-requested",
      instruction_prompt: "Translate faithfully.",
      source_text: "Source text"
    }
  end
end
