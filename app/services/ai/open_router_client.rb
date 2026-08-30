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

    class Error < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    class RetryableError < Error; end
    class PermanentError < Error; end

    def self.serialize_request(model_identifier:, messages:, **options)
      JSON.generate(
        model: model_identifier,
        messages: messages,
        usage: { include: true },
        **options
      )
    end

    def initialize(
      http_factory: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      read_timeout: DEFAULT_READ_TIMEOUT,
      write_timeout: DEFAULT_WRITE_TIMEOUT
    )
      @api_key = ENV.fetch("OPENROUTER_API_KEY")
      @http_factory = http_factory || ->(uri) { Net::HTTP.new(uri.host, uri.port) }
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @write_timeout = write_timeout
    rescue KeyError
      raise PermanentError.new(
        "OPENROUTER_API_KEY is not configured",
        code: "missing_api_key"
      )
    end

    def chat_completion(model_identifier:, instruction_prompt:, source_text:, max_tokens: nil)
      response = perform_request(
        model_identifier: model_identifier,
        messages: [
          { role: "system", content: instruction_prompt },
          { role: "user", content: source_text }
        ],
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
      )
    end

    def read_bounded_response(response)
      validate_content_length!(response)
      body = String.new(encoding: Encoding::BINARY)
      response.read_body do |chunk|
        body << chunk
        raise_response_too_large! if body.bytesize > MAX_RESPONSE_BYTES
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
      content = choice&.dig("message", "content")
      raise invalid_response("assistant content is missing") unless content.is_a?(String)

      usage = body.fetch("usage", {})

      Result.new(
        content: content,
        provider_response_id: body["id"],
        resolved_model_identifier: body["model"],
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
    rescue KeyError, NoMethodError, TypeError => error
      raise invalid_response(error.message)
    end

    def parse_json(body, retryable:)
      JSON.parse(body.to_s)
    rescue JSON::ParserError => error
      error_class = retryable ? RetryableError : PermanentError
      raise error_class.new(
        "OpenRouter returned malformed JSON",
        code: "malformed_json"
      ), cause: error
    end

    def error_for_response(status, body)
      provider_error = body["error"].is_a?(Hash) ? body["error"] : {}
      code = provider_error["code"].presence || "http_#{status}"
      detail = Ai::ErrorSanitizer.call(
        provider_error["message"].presence || "request failed",
        secrets: [ @api_key ]
      )
      error_class = retryable_status?(status) ? RetryableError : PermanentError

      error_class.new(
        "OpenRouter request failed (HTTP #{status}): #{detail}",
        code: code.to_s.first(255)
      )
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
      raise invalid_response("invalid token count")
    end

    def optional_decimal(value)
      return if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      raise invalid_response("invalid cost")
    end
  end
end
