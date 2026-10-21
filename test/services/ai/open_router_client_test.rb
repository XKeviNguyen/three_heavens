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
    assert_equal({ "effort" => "low", "exclude" => true }, payload["reasoning"])
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

  # Measured per family: Qwen honours only a token budget, Gemini 3 thinks
  # least at "minimal"; everything else keeps low effort.
  test "translation reasoning follows what each model family honours" do
    {
      "qwen/qwen3.7-flash" => { "max_tokens" => 1_024, "exclude" => true },
      "google/gemini-3.1-flash-lite" => { "effort" => "minimal", "exclude" => true },
      "anthropic/claude-haiku-5.5" => { "effort" => "low", "exclude" => true },
      "deepseek/deepseek-v4.1-flash" => { "effort" => "low", "exclude" => true }
    }.each do |model, reasoning|
      http = fake_http(status: 200, body: { choices: [ { message: { content: "訳" } } ] })
      build_client(http).chat_completion(**request_attributes, model_identifier: model)

      assert_equal reasoning, JSON.parse(http.last_request.body).fetch("reasoning"), model
    end
  end

  # require_parameters turns "no provider accepts a strict schema" into a 404.
  test "a structured 404 means no provider offers structured output" do
    structured = assert_raises(Ai::OpenRouterClient::PermanentError) do
      build_client(fake_http(status: 404, body: { error: { code: 404, message: "No endpoints found" } }))
        .review_completion(model_identifier: "qwen/qwen3.7-flash", system_prompt: "Review", user_prompt: "Candidate", response_schema: { type: "object" })
    end
    assert_equal "structured_output_unavailable", structured.code

    plain = assert_raises(Ai::OpenRouterClient::PermanentError) do
      build_client(fake_http(status: 404, body: { error: { code: 404, message: "No endpoints found" } })).chat_completion(**request_attributes)
    end
    assert_equal "http_404", plain.code
  end

  # Structured stages require every parameter of their providers, so asking
  # for reasoning would exclude the providers of models without it.
  test "only plain translation requests ask for reasoning" do
    structured = {
      review_completion: { model_identifier: "review/model", system_prompt: "Review", user_prompt: "Candidate" },
      judge_completion: { model_identifier: "judge/model", system_prompt: "Judge", user_prompt: "Candidate" },
      finalization_completion: { model_identifier: "finalizer/model", system_prompt: "Refine", user_prompt: "Draft" }
    }
    structured.each do |method, attributes|
      http = fake_http(status: 200, body: { choices: [ { message: { content: "{}" } } ] })
      build_client(http).public_send(method, **attributes, response_schema: { type: "object" })

      assert_not JSON.parse(http.last_request.body).key?("reasoning"), method
    end
  end

  # OpenRouter bills the tokens of a response cut off at max_tokens, so the
  # failure carries that spend; unreadable usage never makes it retryable.
  test "an incomplete response keeps its billed usage" do
    http = fake_http(
      status: 200,
      body: {
        choices: [ { finish_reason: "length", message: { content: "" } } ],
        usage: {
          prompt_tokens: 900, completion_tokens: 4_096, total_tokens: 4_996, cost: "0.0041",
          completion_tokens_details: { reasoning_tokens: 4_096 }
        }
      }
    )

    error = assert_raises(Ai::OpenRouterClient::IncompleteResponseError) do
      build_client(http).chat_completion(**request_attributes)
    end

    assert_equal "incomplete_response", error.code
    assert_equal 4_096, error.usage.completion_tokens
    assert_equal 4_096, error.usage.reasoning_tokens
    assert_equal BigDecimal("0.0041"), error.usage.cost

    http = fake_http(
      status: 200,
      body: { choices: [ { finish_reason: "length", message: { content: "" } } ], usage: { completion_tokens: "many" } }
    )
    error = assert_raises(Ai::OpenRouterClient::IncompleteResponseError) do
      build_client(http).chat_completion(**request_attributes)
    end
    assert_nil error.usage
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

  # OpenRouter's in-flight budget fills while requests run and clears by
  # itself; an exhausted balance or key limit does not.
  test "retries only the 402 that names the in-flight budget" do
    in_flight = fake_http(status: 402, body: { error: { code: 402, message: "Too many in flight", metadata: { limit_source: "openrouter_in_flight_budget" } } })
    error = assert_raises(Ai::OpenRouterClient::RetryableError) { build_client(in_flight).chat_completion(**request_attributes) }
    assert_equal "http_402", error.code

    # The lasting causes are named, so the page can say which fix applies.
    {
      { limit_source: "openrouter_credits" } => "openrouter_credits_exhausted",
      { limit_source: "openrouter_key_limit" } => "openrouter_key_limit_reached",
      { limit_source: "something_new" } => "http_402",
      nil => "http_402"
    }.each do |metadata, code|
      exhausted = fake_http(status: 402, body: { error: { code: 402, message: "Insufficient credits", metadata: metadata }.compact })
      error = assert_raises(Ai::OpenRouterClient::PermanentError) { build_client(exhausted).chat_completion(**request_attributes) }
      assert_equal code, error.code
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
    [ nil, "" ].each do |api_key|
      error = assert_raises Ai::OpenRouterClient::PermanentError do
        Ai::OpenRouterClient.new(api_key: api_key)
      end

      assert_equal "missing_api_key", error.code
    end
  end

  test "never reads the platform key itself and keeps the injected key out of inspect" do
    http = fake_http(status: 200, body: { choices: [ { message: { content: "ok" } } ] })
    client = Ai::OpenRouterClient.new(api_key: "sk-or-v1-personal-test-key", http_factory: ->(_uri) { http })

    client.chat_completion(**request_attributes)

    assert_equal "Bearer sk-or-v1-personal-test-key", http.last_request["Authorization"]
    assert_not_includes client.inspect, "personal-test-key"
    assert_not_includes client.inspect, "test-openrouter-key"
  end

  test "the managed credential reads the platform key and redacts it" do
    credential = Ai::ProviderCredential.managed

    assert_equal "test-openrouter-key", credential.api_key
    assert_equal "managed", credential.billing_source
    assert_not_includes credential.inspect, "test-openrouter-key"
    assert_not_includes credential.to_s, "test-openrouter-key"
  end

  test "the managed credential prefers the admin-saved key and falls back to the environment" do
    admin = users(:admin)
    ManagedOpenRouterKey.store!("sk-or-v1-saved-by-admin-0000", by: admin)
    assert_equal "sk-or-v1-saved-by-admin-0000", Ai::ProviderCredential.managed.api_key

    ManagedOpenRouterKey.delete!
    assert_equal "test-openrouter-key", Ai::ProviderCredential.managed.api_key
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
    Ai::OpenRouterClient.new(api_key: ENV["OPENROUTER_API_KEY"], http_factory: ->(_uri) { http })
  end

  def request_attributes
    {
      model_identifier: "anthropic/claude-requested",
      instruction_prompt: "Translate faithfully.",
      source_text: "Source text"
    }
  end
end
