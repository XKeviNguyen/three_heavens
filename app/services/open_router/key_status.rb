require "net/http"
require "json"
require "bigdecimal"
require "digest"
require "timeout"

module OpenRouter
  # Checks one OpenRouter API key with GET /api/v1/key, which generates no
  # tokens and costs nothing. It reports whether OpenRouter accepts the key,
  # the key's own credit limit and use, and today's free-model allowance.
  # The account's credit balance is not available to an ordinary key
  # (/api/v1/credits needs a management key), so it is never shown here.
  # The key is sent only to OpenRouter over HTTPS and never stored, logged or
  # returned; results are cached under a digest of it.
  class KeyStatus
    ENDPOINT = URI("https://openrouter.ai/api/v1/key").freeze
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 4
    # Bounds the whole check, however slowly a response arrives.
    TOTAL_TIMEOUT = 6
    MAX_RESPONSE_BYTES = 64 * 1024
    CACHE_TTL = 1.minute
    UNAVAILABLE_CACHE_TTL = 15.seconds

    Status = Data.define(
      :state, :label, :limit, :limit_remaining, :usage_monthly, :free_tier,
      :free_requests_remaining, :free_requests_limit
    ) do
      def valid? = state == "valid"
      def invalid? = state == "invalid"
      def unavailable? = state == "unavailable"
    end

    def self.call(api_key, http: Net::HTTP)
      new(http: http).call(api_key)
    end

    def self.cached(api_key, http: Net::HTTP)
      return if api_key.blank?

      cache_key = "openrouter/key-status/v1/#{Digest::SHA256.hexdigest(api_key)}"
      stored = Rails.cache.read(cache_key)
      return Status.new(**stored.symbolize_keys) if stored.is_a?(Hash)

      status = call(api_key, http: http)
      Rails.cache.write(cache_key, status.to_h, expires_in: status.unavailable? ? UNAVAILABLE_CACHE_TTL : CACHE_TTL)
      status
    end

    def initialize(http:)
      @http = http
    end

    def call(api_key)
      return unavailable if api_key.blank?

      request = Net::HTTP::Get.new(ENDPOINT)
      request["Authorization"] = "Bearer #{api_key}"
      request["Accept"] = "application/json"
      code = body = nil
      Timeout.timeout(TOTAL_TIMEOUT) do
        @http.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true,
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |connection|
          connection.request(request) do |response|
            code = response.code.to_i
            body = bounded_body(response)
          end
        end
      end
      return invalid if code == 401 || code == 403
      return unavailable unless code == 200

      parse(body)
    rescue StandardError => error
      # Only the class is logged: the message could echo the response.
      Rails.logger.warn("OpenRouter key check unavailable: #{error.class}")
      unavailable
    end

    private

    def bounded_body(response)
      body = +""
      response.read_body do |chunk|
        body << chunk
        raise ArgumentError, "response too large" if body.bytesize > MAX_RESPONSE_BYTES
      end
      body
    end

    def parse(body)
      data = JSON.parse(body.to_s).fetch("data")
      raise ArgumentError, "unexpected shape" unless data.is_a?(Hash)

      free = data["free_model_daily_requests"].is_a?(Hash) ? data["free_model_daily_requests"] : {}
      Status.new(
        state: "valid",
        label: data["label"].is_a?(String) ? data["label"].first(100) : nil,
        limit: decimal(data["limit"]),
        limit_remaining: decimal(data["limit_remaining"]),
        usage_monthly: decimal(data["usage_monthly"]),
        free_tier: data["is_free_tier"] == true,
        free_requests_remaining: integer(free["remaining"]),
        free_requests_limit: integer(free["limit"])
      )
    end

    def decimal(value)
      value.is_a?(Numeric) ? BigDecimal(value.to_s) : nil
    end

    def integer(value)
      value.is_a?(Integer) ? value : nil
    end

    def invalid = blank_status("invalid")
    def unavailable = blank_status("unavailable")

    def blank_status(state)
      Status.new(state: state, label: nil, limit: nil, limit_remaining: nil, usage_monthly: nil, free_tier: nil,
                 free_requests_remaining: nil, free_requests_limit: nil)
    end
  end
end
