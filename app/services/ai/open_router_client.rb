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

    def chat_completion(model_identifier:, instruction_prompt:, source_text:)
      response = perform_request(
        model_identifier: model_identifier,
        instruction_prompt: instruction_prompt,
        source_text: source_text
      )

      parse_response(response)
    end

    private

    def perform_request(model_identifier:, instruction_prompt:, source_text:)
      request = Net::HTTP::Post.new(ENDPOINT)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(
        model: model_identifier,
        messages: [
          { role: "system", content: instruction_prompt },
          { role: "user", content: source_text }
        ],
        usage: { include: true }
      )

      http = @http_factory.call(ENDPOINT)
      http.use_ssl = true
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @write_timeout if http.respond_to?(:write_timeout=)
      http.start { |connection| connection.request(request) }
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
