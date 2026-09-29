require "net/http"
require "json"
require "bigdecimal"

module OpenRouter
  # Read-only discovery client for the public OpenRouter model catalog.
  #
  # This is deliberately separate from Ai::OpenRouterClient, which performs
  # paid completion work. The catalog endpoint is public metadata and is
  # fetched without any Authorization header so the provider credential never
  # reaches a discovery request, browser, log, or cache entry.
  class Catalog
    ENDPOINT = URI("https://openrouter.ai/api/v1/models").freeze
    CACHE_KEY = "openrouter/model-catalog/v1"
    CACHE_TTL = 20.minutes
    # After a failed fetch, requests report the catalog as unavailable without
    # contacting OpenRouter until this passes, so an outage cannot turn every
    # search, filter, or page load into another slow upstream request.
    FAILURE_CACHE_KEY = "openrouter/model-catalog/v1/unavailable"
    FAILURE_BACKOFF = 30.seconds
    MAX_RESPONSE_BYTES = 2 * 1024 * 1024
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5
    WRITE_TIMEOUT = 5
    # READ_TIMEOUT bounds each read; this bounds the whole slowly streamed body.
    TOTAL_TIMEOUT = 10
    MAX_MODELS = 4_000
    # Ai::ContextBudget reserves 4_096 output tokens for every provider stage.
    STAGE_OUTPUT_RESERVE = 4_096
    MIN_CONTEXT_TOKENS = 8_192

    class Error < StandardError
      def initialize(message = "The OpenRouter model catalog is unavailable.")
        super
      end
    end

    Model = Data.define(
      :identifier,
      :name,
      :provider,
      :context_length,
      :max_completion_tokens,
      :prompt_price,
      :completion_price,
      :input_modalities,
      :output_modalities,
      :supported_parameters
    ) do
      def text_input?
        input_modalities.include?("text")
      end

      def text_output?
        output_modalities.include?("text")
      end

      def translation_capable?
        text_input? && text_output? &&
          max_completion_tokens.to_i >= STAGE_OUTPUT_RESERVE &&
          context_length.to_i >= MIN_CONTEXT_TOKENS
      end

      def structured_output_capable?
        supported_parameters.include?("response_format") ||
          supported_parameters.include?("structured_outputs")
      end

      def structured_capable?
        translation_capable? && structured_output_capable?
      end

      def free?
        prompt_price == 0 && completion_price == 0
      end

      def roles
        return [] unless translation_capable?

        roles = [ "translator" ]
        roles.concat(%w[reviewer judge finalizer]) if structured_capable?
        roles
      end
    end

    Result = Data.define(:models, :fetched_at)

    # Test seam: automated tests replace the HTTP transport so no real
    # OpenRouter request is ever made from the test suite.
    class << self
      attr_accessor :transport
    end

    # Concurrent cold requests in one process share a single fetch: the first
    # leads it and the others wait for its outcome. Waiters must not re-read
    # the cache, because each request reads through a request-local cache
    # that still answers with the miss it saw before waiting.
    Flight = Struct.new(:result, :done)
    FLIGHT_LOCK = Mutex.new
    FLIGHT_LANDED = ConditionVariable.new
    @flight = nil
    class << self
      attr_accessor :flight
    end

    def self.call(**options)
      new(**options).call
    end

    def initialize(transport: nil, cache: Rails.cache, clock: -> { Time.current })
      @transport = transport || self.class.transport || method(:http_get)
      @cache = cache
      @clock = clock
    end

    def call
      cached_result || shared_fetch
    end

    private

    def cached_result
      cached = @cache.read(CACHE_KEY)
      return cached if cached.is_a?(Result)
      raise Error if @cache.read(FAILURE_CACHE_KEY)

      nil
    end

    def shared_fetch
      flight, leading = FLIGHT_LOCK.synchronize do
        current = self.class.flight
        current ? [ current, false ] : [ self.class.flight = Flight.new, true ]
      end
      if leading
        begin
          flight.result = fetch
        ensure
          FLIGHT_LOCK.synchronize do
            flight.done = true
            self.class.flight = nil
            FLIGHT_LANDED.broadcast
          end
        end
      else
        FLIGHT_LOCK.synchronize { FLIGHT_LANDED.wait(FLIGHT_LOCK) until flight.done }
        raise Error unless flight.result
      end
      flight.result
    end

    def fetch
      body = @transport.call
      result = Result.new(models: normalize(body), fetched_at: @clock.call)
      @cache.write(CACHE_KEY, result, expires_in: CACHE_TTL)
      @cache.delete(FAILURE_CACHE_KEY)
      result
    rescue StandardError
      @cache.write(FAILURE_CACHE_KEY, true, expires_in: FAILURE_BACKOFF)
      raise Error
    end

    def http_get
      http = Net::HTTP.new(ENDPOINT.host, ENDPOINT.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT if http.respond_to?(:write_timeout=)
      request = Net::HTTP::Get.new(ENDPOINT)
      request["Accept"] = "application/json"
      request["Accept-Encoding"] = "identity"

      body = nil
      http.start do |connection|
        connection.request(request) do |response|
          raise Error unless response.is_a?(Net::HTTPSuccess)

          # Streaming read_body does not inflate compressed chunks unless
          # decoding is explicitly enabled.
          response.decode_content = true if response.respond_to?(:decode_content=)

          body = +""
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TOTAL_TIMEOUT
          response.read_body do |chunk|
            body << chunk
            raise Error if body.bytesize > MAX_RESPONSE_BYTES
            raise Error if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          end
        end
        body
      end
    rescue Error
      raise
    rescue StandardError
      raise Error
    end

    def normalize(body)
      parsed = JSON.parse(body.to_s)
      entries = parsed.is_a?(Hash) ? parsed["data"] : nil
      raise Error unless entries.is_a?(Array)
      raise Error if entries.size > MAX_MODELS

      entries.filter_map { |entry| normalize_model(entry) }
    end

    def normalize_model(entry)
      return unless entry.is_a?(Hash)

      identifier = entry["id"]
      return unless identifier.is_a?(String) && identifier.match?(LlmModel::OPENROUTER_IDENTIFIER_FORMAT)

      architecture = entry["architecture"].is_a?(Hash) ? entry["architecture"] : {}
      top_provider = entry["top_provider"].is_a?(Hash) ? entry["top_provider"] : {}
      pricing = entry["pricing"].is_a?(Hash) ? entry["pricing"] : {}

      Model.new(
        identifier: identifier,
        name: display_name(entry, identifier),
        provider: identifier.split("/", 2).first.first(LlmModel::PROVIDER_MAX_LENGTH),
        context_length: positive_integer(entry["context_length"]),
        max_completion_tokens: positive_integer(top_provider["max_completion_tokens"]),
        prompt_price: decimal(pricing["prompt"]),
        completion_price: decimal(pricing["completion"]),
        input_modalities: string_array(architecture["input_modalities"]),
        output_modalities: string_array(architecture["output_modalities"]),
        supported_parameters: string_array(entry["supported_parameters"])
      )
    end

    def display_name(entry, identifier)
      name = entry["name"]
      value = name.is_a?(String) && name.present? ? name : identifier
      value.strip.first(LlmModel::DISPLAY_NAME_MAX_LENGTH)
    end

    def positive_integer(value)
      integer = Integer(value, exception: false)
      return if integer.nil? || integer <= 0

      integer
    end

    def decimal(value)
      return if value.nil?

      parsed = BigDecimal(value.to_s)
      return if parsed.negative?

      parsed
    rescue ArgumentError, TypeError
      nil
    end

    def string_array(value)
      return [] unless value.is_a?(Array)

      value.grep(String).first(50)
    end
  end
end
