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
    # Connecting and the TLS handshake each wait at most OPEN_TIMEOUT, so it
    # stays under half of TOTAL_TIMEOUT.
    OPEN_TIMEOUT = 3
    READ_TIMEOUT = 5
    WRITE_TIMEOUT = 5
    # Bounds the whole fetch: connection, TLS, headers, and the full body.
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
    # leads it and the others wait for its outcome. Callers never re-read the
    # cache after a miss, because each request reads through a request-local
    # cache that still answers with the miss it saw. A caller descheduled
    # between its miss and joining takes the outcome that landed meanwhile
    # instead of leading a duplicate fetch, so the latest landed flight is
    # kept only while a caller that started before it is still running.
    Flight = Struct.new(:generation, :result, :done)
    FLIGHT_LOCK = Mutex.new
    FLIGHT_LANDED = ConditionVariable.new
    @flight = nil
    @landed = nil
    @generation = 0
    @callers = 0
    class << self
      attr_accessor :flight, :landed, :generation, :callers
    end

    def self.call(**options)
      new(**options).call
    end

    # endpoint and total_timeout are test seams, like transport: production
    # always fetches the fixed ENDPOINT within TOTAL_TIMEOUT.
    def initialize(transport: nil, cache: Rails.cache, clock: -> { Time.current },
                   endpoint: ENDPOINT, total_timeout: TOTAL_TIMEOUT)
      @transport = transport || self.class.transport || method(:http_get)
      @cache = cache
      @clock = clock
      @endpoint = endpoint
      @total_timeout = total_timeout
    end

    def call
      seen = FLIGHT_LOCK.synchronize do
        self.class.callers += 1
        self.class.generation
      end
      begin
        cached_result || shared_fetch(seen)
      ensure
        FLIGHT_LOCK.synchronize do
          self.class.callers -= 1
          self.class.landed = nil if self.class.callers.zero?
        end
      end
    end

    private

    def cached_result
      cached = @cache.read(CACHE_KEY)
      return cached if cached.is_a?(Result)
      raise Error if @cache.read(FAILURE_CACHE_KEY)

      nil
    end

    # seen is the number of flights that had landed before this caller read
    # the cache; any flight landing later is at least as fresh as its miss.
    def shared_fetch(seen)
      flight, leading = FLIGHT_LOCK.synchronize do
        landed = self.class.landed
        if landed && landed.generation > seen then [ landed, false ]
        elsif self.class.flight then [ self.class.flight, false ]
        else [ self.class.flight = Flight.new, true ]
        end
      end
      if leading
        begin
          flight.result = fetch
        ensure
          FLIGHT_LOCK.synchronize do
            flight.generation = self.class.generation += 1
            flight.done = true
            self.class.flight = nil
            self.class.landed = flight
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
      http = DeadlineHTTP.new(@endpoint.host, @endpoint.port)
      http.deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @total_timeout
      http.use_ssl = @endpoint.scheme == "https"
      http.open_timeout = [ OPEN_TIMEOUT, @total_timeout ].min
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = [ WRITE_TIMEOUT, @total_timeout ].min
      # A retried GET would reconnect after the budget is already spent.
      http.max_retries = 0
      request = Net::HTTP::Get.new(@endpoint)
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
          response.read_body do |chunk|
            body << chunk
            raise Error if body.bytesize > MAX_RESPONSE_BYTES
          end
        end
        body
      end
    rescue Error
      raise
    rescue StandardError
      raise Error
    end

    # Net::HTTP bounds each connect step and each wait for data separately,
    # so an upstream that trickles bytes just under READ_TIMEOUT never trips
    # them. This client caps every wait on its connection by what remains of
    # one monotonic deadline; connecting and the TLS handshake are each
    # capped by open_timeout, which never exceeds the total budget.
    class DeadlineHTTP < Net::HTTP
      attr_accessor :deadline

      private

      def on_connect
        raise Net::OpenTimeout if deadline <= DeadlineReads.now

        @socket.io.extend(DeadlineReads).deadline = deadline
      end
    end

    # Every read Net::BufferedIO makes goes through read_nonblock, and it
    # waits only after one reports that no data is ready. Checking and
    # waiting here bounds headers, chunk framing, trailers, and the body,
    # whether the peer trickles bytes (TLS records included) or floods them.
    # Headers and framing are not counted by the body limit, so all bytes
    # read are capped too.
    module DeadlineReads
      MAX_BYTES = MAX_RESPONSE_BYTES + 64 * 1024

      attr_accessor :deadline

      def self.now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def read_nonblock(...)
        raise Net::ReadTimeout if deadline <= DeadlineReads.now

        result = super(...)
        if result.is_a?(String)
          @bytes_read = @bytes_read.to_i + result.bytesize
          raise Error if @bytes_read > MAX_BYTES
        elsif result == :wait_readable || result == :wait_writable
          remaining = deadline - DeadlineReads.now
          raise Net::ReadTimeout if remaining <= 0
          to_io.public_send(result, [ remaining, READ_TIMEOUT ].min) or raise Net::ReadTimeout
        end
        result
      end
    end
    private_constant :DeadlineHTTP, :DeadlineReads

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
