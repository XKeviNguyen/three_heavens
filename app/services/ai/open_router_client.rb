require "bigdecimal"
require "json"
require "net/http"
require "openssl"

module Ai
  class OpenRouterClient
    ENDPOINT = URI("https://openrouter.ai/api/v1/chat/completions")
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_READ_TIMEOUT = 60
    DEFAULT_WRITE_TIMEOUT = 10
    MAX_RESPONSE_BYTES = 1_048_576
    CONTEXT_COMPRESSION_DISABLED = [
      { id: "context-compression", enabled: false }.freeze
    ].freeze
    ACCEPTED_FINISH_REASON = "stop"
    # Reasoning models think before they answer, and OpenRouter counts that
    # against max_tokens. Low effort leaves most of the budget for the answer,
    # and the reasoning text itself is never returned. Only plain translation
    # requests send it: structured stages require every parameter
    # (provider.require_parameters), which would exclude providers of models
    # without reasoning.
    REASONING = { effort: "low", exclude: true }.freeze
    # Families measured on 2026-10-21 (a real 3,400-character part): Qwen
    # ignores effort but honours a token budget (70 s -> 29 s); Gemini 3
    # thinks least at "minimal" (none at all). The rest keep low effort.
    REASONING_BY_PREFIX = {
      "qwen/" => { max_tokens: 1_024, exclude: true }.freeze,
      "google/gemini-" => { effort: "minimal", exclude: true }.freeze
    }.freeze

    def self.reasoning_for(model_identifier)
      REASONING_BY_PREFIX.find { |prefix, _| model_identifier.to_s.start_with?(prefix) }&.last || REASONING
    end
    IN_FLIGHT_BUDGET_LIMIT = "openrouter_in_flight_budget"
    # The two lasting 402 causes get their own codes: an empty account and a
    # spent per-key limit need different fixes, and both looked the same.
    PAYMENT_LIMIT_CODES = {
      "openrouter_credits" => "openrouter_credits_exhausted",
      "openrouter_key_limit" => "openrouter_key_limit_reached"
    }.freeze

    BoundedResponse = Data.define(:code, :body)

    Result = Data.define(
      :content,
      :provider_response_id,
      :resolved_model_identifier,
      :prompt_tokens,
      :completion_tokens,
      :total_tokens,
      :cached_tokens,
      :reasoning_tokens,
      :cost
    )
    Usage = Data.define(:prompt_tokens, :completion_tokens, :total_tokens, :cached_tokens, :reasoning_tokens, :cost)

    class Error < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    class RetryableError < Error; end
    class PermanentError < Error; end

    # The provider generated (and billed) tokens but stopped before finishing,
    # e.g. at max_tokens. Its usage is kept so the spend is recorded.
    class IncompleteResponseError < PermanentError
      attr_reader :usage

      def initialize(message, code:, usage:)
        @usage = usage
        super(message, code: code)
      end
    end

    def self.serialize_request(model_identifier:, messages:, **options)
      request = {
        model: model_identifier,
        messages: messages,
        usage: { include: true }
      }.merge(options)
      request[:plugins] = CONTEXT_COMPRESSION_DISABLED
      JSON.generate(request)
    end

    # The key is always injected (see Ai::BillingPolicy); the client never
    # reads OPENROUTER_API_KEY itself, so a missing personal key can never
    # turn into a request on the platform's key.
    def initialize(
      api_key:,
      http_factory: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      write_timeout: DEFAULT_WRITE_TIMEOUT
    )
      if api_key.blank?
        raise PermanentError.new(
          "The OpenRouter API key is not configured",
          code: "missing_api_key"
        )
      end

      @api_key = api_key
      @http_factory = http_factory || ->(uri) { Net::HTTP.new(uri.host, uri.port) }
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
    end

    def inspect
      "#<#{self.class.name} [FILTERED]>"
    end

    def chat_completion(model_identifier:, instruction_prompt:, source_text:, max_tokens: nil)
      response = perform_request(
        model_identifier: model_identifier,
        messages: [
          { role: "system", content: instruction_prompt },
          { role: "user", content: source_text }
        ],
        reasoning: self.class.reasoning_for(model_identifier),
        **max_tokens_option(max_tokens)
      )

      parse_response(response)
    end

    def review_completion(model_identifier:, system_prompt:, user_prompt:, response_schema:, max_tokens: nil)
      structured_completion(
        model_identifier: model_identifier,
        system_prompt: system_prompt,
        user_prompt: user_prompt,
        response_schema: response_schema,
        schema_name: "blind_translation_review",
        max_tokens: max_tokens
      )
    end

    def judge_completion(model_identifier:, system_prompt:, user_prompt:, response_schema:, max_tokens: nil)
      structured_completion(
        model_identifier: model_identifier,
        system_prompt: system_prompt,
        user_prompt: user_prompt,
        response_schema: response_schema,
        schema_name: "blind_translation_judgment",
        max_tokens: max_tokens
      )
    end

    def finalization_completion(model_identifier:, system_prompt:, user_prompt:, response_schema:, max_tokens: nil)
      structured_completion(
        model_identifier: model_identifier,
        system_prompt: system_prompt,
        user_prompt: user_prompt,
        response_schema: response_schema,
        schema_name: "final_translation_refinement",
        max_tokens: max_tokens
      )
    end

    private

    def structured_completion(model_identifier:, system_prompt:, user_prompt:, response_schema:, schema_name:, max_tokens:)
      response = perform_request(
        model_identifier: model_identifier,
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: user_prompt }
        ],
        response_format: {
          type: "json_schema",
          json_schema: {
            name: schema_name,
            strict: true,
            schema: response_schema
          }
        },
        provider: { require_parameters: true },
        **max_tokens_option(max_tokens)
      )

      parse_response(response)
    rescue PermanentError => error
      raise unless error.code == "http_404"

      # With require_parameters, a 404 means no provider of this model
      # accepts a strict JSON schema, not that the model is unknown.
      raise PermanentError.new(
        "No OpenRouter provider serves this model with structured output",
        code: "structured_output_unavailable"
      ), cause: nil
    end

    def perform_request(model_identifier:, messages:, **options)
      request = Net::HTTP::Post.new(ENDPOINT)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = self.class.serialize_request(
        model_identifier: model_identifier,
        messages: messages,
        **options
      )

      http = @http_factory.call(ENDPOINT)
      http.use_ssl = true
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @write_timeout if http.respond_to?(:write_timeout=)
      bounded_response = nil
      raw_response = http.start do |connection|
        connection.request(request) do |response|
          bounded_response = read_bounded_response(response)
        end
      end
      bounded_response || read_materialized_response(raw_response)
    rescue Net::OpenTimeout,
           Net::ReadTimeout,
           Net::WriteTimeout,
           Timeout::Error,
           SocketError,
           EOFError,
           Errno::ECONNREFUSED,
           Errno::ECONNRESET,
           Errno::EHOSTUNREACH,
           OpenSSL::SSL::SSLError => error
      raise RetryableError.new(
        "OpenRouter network request failed: #{error.class}",
        code: "network_error"
      ), cause: nil
    end

    def read_bounded_response(response)
      validate_content_length!(response)
      body = String.new(encoding: Encoding::BINARY)
      response.read_body do |chunk|
        raise_response_too_large! if chunk.bytesize > MAX_RESPONSE_BYTES - body.bytesize

        body << chunk
      end
      BoundedResponse.new(code: response.code, body: body)
    end

    def read_materialized_response(response)
      body = response.body.to_s
      raise_response_too_large! if body.bytesize > MAX_RESPONSE_BYTES
      BoundedResponse.new(code: response.code, body: body)
    end

    def validate_content_length!(response)
      return unless response.respond_to?(:[])

      length = Integer(response["content-length"], exception: false)
      raise_response_too_large! if length && length > MAX_RESPONSE_BYTES
    end

    def raise_response_too_large!
      raise PermanentError.new(
        "OpenRouter response exceeded the safe size limit",
        code: "response_too_large"
      )
    end

    def max_tokens_option(value)
      value ? { max_tokens: Integer(value) } : {}
    end

    def parse_response(response)
      status = Integer(response.code)
      body = parse_json(response.body, retryable: retryable_status?(status))

      unless status.between?(200, 299)
        raise error_for_response(status, body)
      end

      choice = body.fetch("choices").first
      usage = body.fetch("usage", {})
      unless choice&.fetch("finish_reason", nil) == ACCEPTED_FINISH_REASON
        raise IncompleteResponseError.new(
          "The AI response was incomplete",
          code: "incomplete_response",
          # Unreadable usage must not turn this permanent failure retryable.
          usage: (usage_from(usage) rescue nil)
        )
      end

      content = choice&.dig("message", "content")
      raise invalid_response("assistant content is missing") unless content.is_a?(String)

      Result.new(
        content: content,
        provider_response_id: body["id"],
        resolved_model_identifier: body["model"],
        **usage_from(usage).to_h
      )
    rescue KeyError, NoMethodError, TypeError
      raise invalid_response("unexpected response shape"), cause: nil
    end

    def usage_from(usage)
      Usage.new(
        prompt_tokens: optional_integer(usage["prompt_tokens"]),
        completion_tokens: optional_integer(usage["completion_tokens"]),
        total_tokens: optional_integer(usage["total_tokens"]),
        cached_tokens: optional_integer(
          usage.dig("prompt_tokens_details", "cached_tokens") ||
            usage["cached_tokens"]
        ),
        reasoning_tokens: optional_integer(
          usage.dig("completion_tokens_details", "reasoning_tokens") ||
            usage["reasoning_tokens"]
        ),
        cost: optional_decimal(usage["cost"])
      )
    end

    def parse_json(body, retryable:)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      error_class = retryable ? RetryableError : PermanentError
      raise error_class.new(
        "OpenRouter returned malformed JSON",
        code: "malformed_json"
      ), cause: nil
    end

    def error_for_response(status, body)
      # Provider errors may echo prompts, credentials, or reasoning. Only the
      # HTTP status is safe to retain in job failures, logs, and owner pages.
      limit_source = status == 402 ? payment_limit_source(body) : nil
      retryable = retryable_status?(status) || limit_source == IN_FLIGHT_BUDGET_LIMIT
      error_class = retryable ? RetryableError : PermanentError

      error_class.new(
        "OpenRouter request failed (HTTP #{status})",
        code: PAYMENT_LIMIT_CODES.fetch(limit_source, "http_#{status}")
      )
    end

    # A 402 names its cause in error.metadata.limit_source. Running and just
    # finished requests can fill the account's in-flight budget for a moment;
    # that clears by itself, so only it is retried. Only this fixed token is
    # read from the body.
    def payment_limit_source(body)
      metadata = body.is_a?(Hash) && body["error"].is_a?(Hash) ? body["error"]["metadata"] : nil
      source = metadata.is_a?(Hash) ? metadata["limit_source"] : nil
      source if source == IN_FLIGHT_BUDGET_LIMIT || PAYMENT_LIMIT_CODES.key?(source)
    end

    def retryable_status?(status)
      status.between?(200, 299) || status == 429 || status >= 500
    end

    def invalid_response(detail)
      RetryableError.new(
        "OpenRouter response was invalid: #{Ai::ErrorSanitizer.call(detail)}",
        code: "invalid_response"
      )
    end

    def optional_integer(value)
      return if value.nil?

      Integer(value)
    rescue ArgumentError
      raise invalid_response("invalid token count"), cause: nil
    end

    def optional_decimal(value)
      return if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      raise invalid_response("invalid cost"), cause: nil
    end
  end
end
