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

  class StreamingResponse
    attr_reader :code

    def initialize(code:, chunks:, content_length: nil)
      @code = code.to_s
      @chunks = chunks
      @content_length = content_length
    end

    def [](name)
      @content_length.to_s if name.downcase == "content-length" && @content_length
    end

    def read_body
      @chunks.each { |chunk| yield chunk }
    end
  end

  class StreamingHttp < FakeHttp
    def request(request)
      @last_request = request
      yield @response
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
      [ { "id" => "context-compression", "enabled" => false } ],
      payload["plugins"]
    )
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

  test "sends an explicit completion limit when provided" do
    http = fake_http(status: 200, body: { choices: [ { message: { content: "Translated" } } ] })
    client = build_client(http)

    client.chat_completion(**request_attributes, max_tokens: 1_234)

    assert_equal 1_234, JSON.parse(http.last_request.body).fetch("max_tokens")
  end

  test "fails closed for truncated and unexpected completion termination" do
    requests = [
      ->(client) { client.chat_completion(**request_attributes) },
      ->(client) do
        client.review_completion(
          model_identifier: "review/model",
          system_prompt: "Review",
          user_prompt: "Candidate",
          response_schema: { type: "object" }
        )
      end,
      ->(client) do
        client.judge_completion(
          model_identifier: "judge/model",
          system_prompt: "Judge",
          user_prompt: "Candidate",
          response_schema: { type: "object" }
        )
      end,
      ->(client) do
        client.finalization_completion(
          model_identifier: "finalizer/model",
          system_prompt: "Refine",
          user_prompt: "Draft",
          response_schema: { type: "object" }
        )
      end
    ]

    %w[length tool_calls content_filter error].each_with_index do |finish_reason, index|
      http = fake_http(
        status: 200,
        body: {
          choices: [
            { finish_reason: finish_reason, message: { content: "Valid-looking partial output" } }
          ]
        }
      )

      error = assert_raises(Ai::OpenRouterClient::PermanentError) do
        requests.fetch(index).call(build_client(http))
      end
      assert_equal "incomplete_response", error.code
      assert_not_includes error.message, finish_reason
    end
  end

  test "fails closed when completion termination is missing" do
    http = fake_http(
      status: 200,
      body: { choices: [ { finish_reason: nil, message: { content: "Partial" } } ] }
    )

    error = assert_raises(Ai::OpenRouterClient::PermanentError) do
      build_client(http).chat_completion(**request_attributes)
    end

    assert_equal "incomplete_response", error.code
  end

  test "rejects a materialized response above the byte ceiling without exposing its body" do
    response = FakeResponse.new(
      code: "200",
      body: "x" * (Ai::OpenRouterClient::MAX_RESPONSE_BYTES + 1)
    )
    error = assert_raises(Ai::OpenRouterClient::PermanentError) do
      build_client(FakeHttp.new(response: response)).chat_completion(**request_attributes)
    end

    assert_equal "response_too_large", error.code
    assert_not_includes error.message, "x" * 100
  end

  test "rejects content length and streamed chunks above the byte ceiling" do
    oversized_length = StreamingResponse.new(
      code: 200,
      chunks: [],
      content_length: Ai::OpenRouterClient::MAX_RESPONSE_BYTES + 1
    )
    streamed = StreamingResponse.new(
      code: 200,
      chunks: [ "語" * 200_000, "語" * 200_000 ]
    )

    [ oversized_length, streamed ].each do |response|
      error = assert_raises(Ai::OpenRouterClient::PermanentError) do
        build_client(StreamingHttp.new(response: response)).chat_completion(**request_attributes)
      end
      assert_equal "response_too_large", error.code
    end
  end

  test "sends strict structured review requests without changing translation calls" do
    http = fake_http(
      status: 200,
      body: {
        choices: [ { message: { content: '{"evaluations":[]}' } } ]
      }
    )
    client = build_client(http)
    schema = {
      type: "object",
      properties: { evaluations: { type: "array" } },
      required: [ "evaluations" ],
      additionalProperties: false
    }

    result = client.review_completion(
      model_identifier: "reviewer/model",
      system_prompt: "Review anonymous candidates.",
      user_prompt: "Candidate A: translated text",
      response_schema: schema
    )

    payload = JSON.parse(http.last_request.body)
    assert_equal "reviewer/model", payload["model"]
    assert_equal({ "require_parameters" => true }, payload["provider"])
    assert_equal "json_schema", payload.dig("response_format", "type")
    assert_equal "blind_translation_review",
                 payload.dig("response_format", "json_schema", "name")
    assert_equal true, payload.dig("response_format", "json_schema", "strict")
    assert_equal JSON.parse(JSON.generate(schema)),
                 payload.dig("response_format", "json_schema", "schema")
    assert_equal(
      [
        { "role" => "system", "content" => "Review anonymous candidates." },
        { "role" => "user", "content" => "Candidate A: translated text" }
      ],
      payload["messages"]
    )
    assert_equal '{"evaluations":[]}', result.content
  end

  test "sends judge requests through the strict structured output boundary" do
    http = fake_http(
      status: 200,
      body: {
        choices: [ { message: { content: '{"rankings":[]}' } } ]
      }
    )
    client = build_client(http)
    schema = {
      type: "object",
      properties: { rankings: { type: "array" } },
      required: [ "rankings" ],
      additionalProperties: false
    }

    result = client.judge_completion(
      model_identifier: "judge/model",
      system_prompt: "Judge anonymous candidates.",
      user_prompt: "Candidate A: translated text",
      response_schema: schema
    )

    payload = JSON.parse(http.last_request.body)
    assert_equal "judge/model", payload["model"]
    assert_equal({ "require_parameters" => true }, payload["provider"])
    assert_equal "blind_translation_judgment",
                 payload.dig("response_format", "json_schema", "name")
    assert_equal true, payload.dig("response_format", "json_schema", "strict")
    assert_equal '{"rankings":[]}', result.content
  end

  test "sends finalization requests through a separate strict structured output contract" do
    http = fake_http(
      status: 200,
      body: {
        choices: [ { message: { content: '{"proposed_translation":"Final"}' } } ]
      }
    )
    client = build_client(http)
    schema = {
      type: "object",
      properties: { proposed_translation: { type: "string" } },
      required: [ "proposed_translation" ],
      additionalProperties: false
    }

    result = client.finalization_completion(
      model_identifier: "finalizer/model",
      system_prompt: "Refine the translation.",
      user_prompt: "Untrusted draft data",
      response_schema: schema
    )

    payload = JSON.parse(http.last_request.body)
    assert_equal "finalizer/model", payload["model"]
    assert_equal({ "require_parameters" => true }, payload["provider"])
    assert_equal "final_translation_refinement",
                 payload.dig("response_format", "json_schema", "name")
    assert_equal true, payload.dig("response_format", "json_schema", "strict")
    assert_equal '{"proposed_translation":"Final"}', result.content
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

      assert_equal "http_#{status}", error.code
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

    assert_equal "http_400", error.code
    assert_not_includes error.message, "test-openrouter-key"
    assert_not_includes error.message, "another-secret"
    assert_equal "OpenRouter request failed (HTTP 400)", error.message
  end

  test "provider error payloads cannot enter messages codes or exception causes" do
    [ 400, 429, 503 ].each do |status|
      client = build_client(fake_http(status: status, body: {
        error: { code: "PRIVATE_PROVIDER_CODE", message: "PRIVATE_SOURCE_AND_REASONING" }
      }))
      error = assert_raises Ai::OpenRouterClient::Error do
        client.chat_completion(**request_attributes)
      end
      assert_equal "http_#{status}", error.code
      assert_not_includes error.full_message, "PRIVATE_"
    end
  end

  test "malformed provider shapes and JSON do not retain raw bodies in exceptions" do
    [ "PRIVATE_INVALID_JSON", '{"choices":"PRIVATE_WRONG_SHAPE"}' ].each do |body|
      client = build_client(FakeHttp.new(response: FakeResponse.new(code: "200", body: body)))
      error = assert_raises Ai::OpenRouterClient::Error do
        client.chat_completion(**request_attributes)
      end
      assert_not_includes error.full_message, "PRIVATE_"
      assert_nil error.cause
    end
  end

  test "structured validators discard parser causes containing private provider output" do
    [ BlindReviews::ResponseValidator, Judging::ResponseValidator ].each do |validator|
      error = assert_raises Ai::OpenRouterClient::Error do
        validator.call(content: "PRIVATE_PROVIDER_OUTPUT", expected_labels: [ "Candidate A" ])
      end
      assert_nil error.cause
      assert_not_includes error.full_message, "PRIVATE_PROVIDER_OUTPUT"
    end
    error = assert_raises Ai::OpenRouterClient::Error do
      Finalizations::ResponseValidator.call(content: "PRIVATE_PROVIDER_OUTPUT")
    end
    assert_nil error.cause
    assert_not_includes error.full_message, "PRIVATE_PROVIDER_OUTPUT"
  end

  test "classifies network errors as retryable without exposing details" do
    http = FakeHttp.new(error: Net::ReadTimeout.new("private response body"))
    client = build_client(http)

    error = assert_raises Ai::OpenRouterClient::RetryableError do
      client.chat_completion(**request_attributes)
    end

    assert_equal "network_error", error.code
    assert_not_includes error.message, "private response body"
    assert_nil error.cause
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
    body = body.deep_dup
    if status.between?(200, 299)
      body.fetch(:choices, []).each do |choice|
        choice[:finish_reason] = "stop" unless choice.key?(:finish_reason)
      end
    end
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
