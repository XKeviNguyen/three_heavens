require "test_helper"
require "io/wait"
require "socket"
require "tmpdir"

module OpenRouter
  class CatalogTest < ActiveSupport::TestCase
    def teardown
      OpenRouter::Catalog.transport = nil
    end

    test "endpoint is fixed HTTPS and never accepts an arbitrary URL" do
      assert_equal "openrouter.ai", OpenRouter::Catalog::ENDPOINT.host
      assert_equal "/api/v1/models", OpenRouter::Catalog::ENDPOINT.path
      assert_equal "https", OpenRouter::Catalog::ENDPOINT.scheme
    end

    test "normalizes allowlisted catalog metadata" do
      result = build_catalog(model_entry).call

      model = result.models.sole
      assert_equal "anthropic/claude-3.5-haiku", model.identifier
      assert_equal "anthropic", model.provider
      assert_equal "Anthropic: Claude 3.5 Haiku", model.name
      assert_equal 200_000, model.context_length
      assert_equal 8_192, model.max_completion_tokens
      assert_equal BigDecimal("0.0000008"), model.prompt_price
      assert_equal BigDecimal("0.000004"), model.completion_price
      assert_includes model.input_modalities, "text"
      assert_includes model.output_modalities, "text"
      assert model.translation_capable?
      assert model.structured_capable?
      refute model.free?
    end

    test "rejects malformed JSON" do
      catalog = OpenRouter::Catalog.new(transport: -> { "not-json" }, cache: memory_cache)

      assert_raises(OpenRouter::Catalog::Error) { catalog.call }
    end

    test "rejects a malformed payload shape" do
      catalog = OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => "nope") }, cache: memory_cache)

      assert_raises(OpenRouter::Catalog::Error) { catalog.call }
    end

    test "rejects oversized catalogs" do
      entries = Array.new(OpenRouter::Catalog::MAX_MODELS + 1) { model_entry }
      catalog = OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => entries) }, cache: memory_cache)

      assert_raises(OpenRouter::Catalog::Error) { catalog.call }
    end

    test "network failures and timeouts raise a safe generic error" do
      catalog = OpenRouter::Catalog.new(
        transport: -> { raise Net::ReadTimeout, "timeout for sk-or-secret-value" },
        cache: memory_cache
      )

      error = assert_raises(OpenRouter::Catalog::Error) { catalog.call }
      assert_equal "The OpenRouter model catalog is unavailable.", error.message
      refute_includes error.message, "sk-or"
    end

    test "drops malformed identifiers and normalizes pricing safely" do
      entries = [
        model_entry,
        model_entry.merge("id" => "not-a-valid-identifier"),
        model_entry.merge("id" => "vendor/model", "pricing" => { "prompt" => "oops", "completion" => "0" })
      ]
      result = OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => entries) }, cache: memory_cache).call

      assert_equal 2, result.models.size
      unpriced = result.models.find { |model| model.identifier == "vendor/model" }
      assert_nil unpriced.prompt_price
      assert_equal BigDecimal("0"), unpriced.completion_price
      refute unpriced.free?
    end

    test "classifies text-only and structured compatibility" do
      text_only = OpenRouter::Catalog::Model.new(
        identifier: "vendor/text-only",
        name: "Text only",
        provider: "vendor",
        context_length: 32_000,
        max_completion_tokens: 8_192,
        prompt_price: BigDecimal("0"),
        completion_price: BigDecimal("0"),
        input_modalities: [ "text" ],
        output_modalities: [ "text" ],
        supported_parameters: [ "max_tokens" ]
      )
      assert text_only.translation_capable?
      refute text_only.structured_capable?
      assert_equal [ "translator" ], text_only.roles
      assert text_only.free?

      image_only = OpenRouter::Catalog::Model.new(
        identifier: "vendor/image",
        name: "Image",
        provider: "vendor",
        context_length: 32_000,
        max_completion_tokens: 8_192,
        prompt_price: BigDecimal("0"),
        completion_price: BigDecimal("0"),
        input_modalities: [ "image" ],
        output_modalities: [ "text" ],
        supported_parameters: [ "response_format" ]
      )
      refute image_only.translation_capable?
      assert_empty image_only.roles
    end

    test "default HTTP transport returns the streamed response body" do
      with_server(->(socket) { respond(socket, '{"data":[]}') }) do |server|
        assert_empty OpenRouter::Catalog.new(cache: memory_cache, endpoint: server.endpoint).call.models
      end
    end

    test "default HTTP transport rejects a non-success status" do
      with_server(->(socket) { respond(socket, "nope", status: "503 Service Unavailable") }) do |server|
        assert_raises(OpenRouter::Catalog::Error) do
          OpenRouter::Catalog.new(cache: memory_cache, endpoint: server.endpoint).call
        end
      end
    end

    test "a body streamed within the total deadline is read completely" do
      with_server(->(socket) { respond(socket, catalog_body, every: 0.1, chunks: 4) }) do |server|
        catalog = OpenRouter::Catalog.new(cache: memory_cache, endpoint: server.endpoint, total_timeout: 2)

        assert_equal 1, catalog.call.models.size
      end
    end

    # Every chunk arrives well inside READ_TIMEOUT, so only a deadline over
    # the whole read can stop the request thread from waiting for all of them.
    test "the total deadline aborts a body that trickles in under the read timeout" do
      assert_operator 1.9, :<, OpenRouter::Catalog::READ_TIMEOUT
      with_server(->(socket) { respond(socket, catalog_body, every: 1.9, chunks: 4) }) do |server|
        assert_aborted_near_deadline(server.endpoint)
      end
    end

    test "the total deadline includes time spent waiting for response headers" do
      with_server(->(socket) { respond(socket, catalog_body, headers_after: 3) }) do |server|
        assert_aborted_near_deadline(server.endpoint)
      end
    end

    # The peer accepts the TCP connection but never answers the TLS
    # handshake, which OPEN_TIMEOUT alone would let run for three seconds.
    test "the total deadline includes the connection and TLS handshake" do
      with_server(->(socket) { socket.read }) do |server|
        assert_aborted_near_deadline(server.endpoint(scheme: "https"))
      end
    end

    test "uses the injected cache for the TTL window" do
      calls = 0
      cache = memory_cache
      transport = lambda do
        calls += 1
        JSON.generate("data" => [ model_entry ])
      end
      catalog = OpenRouter::Catalog.new(transport: transport, cache: cache, clock: -> { Time.current })

      2.times { catalog.call }

      assert_equal 1, calls
      cached = cache.read(OpenRouter::Catalog::CACHE_KEY)
      assert_instance_of OpenRouter::Catalog::Result, cached
      assert_equal 1, cached.models.size
    end

    test "a failed fetch is not retried upstream until the bounded backoff passes, then recovers" do
      calls = 0
      failing = true
      transport = lambda do
        calls += 1
        raise Net::OpenTimeout, "upstream down" if failing

        JSON.generate("data" => [ model_entry ])
      end
      catalog = OpenRouter::Catalog.new(transport: transport, cache: memory_cache, clock: -> { Time.current })

      5.times { assert_raises(OpenRouter::Catalog::Error) { catalog.call } }
      assert_equal 1, calls, "repeated opens during an outage must not reach upstream again"

      failing = false
      travel OpenRouter::Catalog::FAILURE_BACKOFF + 1.second do
        assert_equal 1, catalog.call.models.size
        assert_equal 2, calls
        catalog.call
        assert_equal 2, calls, "a successful fetch replaces the failure state and is cached"
      end
    end

    test "a later failure after the cache expires starts a new bounded backoff" do
      calls = 0
      failing = false
      transport = lambda do
        calls += 1
        raise Net::ReadTimeout, "upstream down" if failing

        JSON.generate("data" => [ model_entry ])
      end
      catalog = OpenRouter::Catalog.new(transport: transport, cache: memory_cache, clock: -> { Time.current })
      catalog.call

      failing = true
      travel OpenRouter::Catalog::CACHE_TTL + 1.second do
        3.times { assert_raises(OpenRouter::Catalog::Error) { catalog.call } }
        assert_equal 2, calls
      end
    end

    # Production requests read through a request-local cache that memoizes a
    # miss, so no caller may lead a second fetch after one has started, even
    # when it only reaches the flight after that flight has landed.
    test "concurrent callers share one upstream fetch through cold, failure, backoff, and retry" do
      Dir.mktmpdir("catalog-cache-") do |directory|
        cache = LocalCachedFileStore.new(directory)
        [ 1, 2, 8, 32 ].each do |count|
          cache.clear
          upstream = Queue.new
          failing = false
          transport = gated_transport(upstream) { failing }

          results = run_callers(count, cache:, transport:, gated: upstream)
          assert_equal 1, upstream.size, "#{count} cold callers"
          assert_equal [ 1 ], results.map { it.models.size }.uniq

          cache.clear
          failing = true
          results = run_callers(count, cache:, transport:, gated: upstream)
          assert_equal 2, upstream.size, "#{count} cold callers during an outage"
          assert results.all?(OpenRouter::Catalog::Error), results.inspect

          results = run_callers(count, cache:, transport:)
          assert_equal 2, upstream.size, "#{count} callers inside the failure backoff"
          assert results.all?(OpenRouter::Catalog::Error), results.inspect

          failing = false
          travel OpenRouter::Catalog::FAILURE_BACKOFF + 1.second do
            results = run_callers(count, cache:, transport:, gated: upstream)
          end
          assert_equal 3, upstream.size, "#{count} callers after the backoff"
          assert_equal [ 1 ], results.map { it.models.size }.uniq
        end
      end
    end

    test "concurrent callers share one deadline-bounded fetch of a slow body" do
      Dir.mktmpdir("catalog-cache-") do |directory|
        cache = LocalCachedFileStore.new(directory)
        [ 1, 2, 8, 32 ].each do |count|
          cache.clear
          with_server(->(socket) { respond(socket, catalog_body, every: 0.4, chunks: 4) }) do |server|
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            results = run_callers(count, cache:, endpoint: server.endpoint, total_timeout: 0.5)
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

            assert_equal 1, server.connections, "#{count} callers"
            assert results.all?(OpenRouter::Catalog::Error), results.inspect
            assert_operator elapsed, :<, 1.2, "#{count} callers waited #{elapsed.round(2)}s"
          end
        end
      end
    end

    # Replays the schedule that used to fetch twice: A misses and is
    # descheduled; B misses, fetches, lands, and clears the flight; A resumes
    # still holding its stale miss, as its request-local cache would.
    test "a caller that missed before another's flight landed takes that outcome" do
      [ :success, :failure ].each do |outcome|
        store = memory_cache
        calls = 0
        failing = outcome == :failure
        transport = lambda do
          calls += 1
          raise Net::ReadTimeout, "upstream down" if failing

          catalog_body
        end
        paused = Queue.new
        resume = Queue.new
        caller_a = Thread.new do
          OpenRouter::Catalog.new(transport:, cache: StaleMissCache.new(store, paused:, resume:)).call
        rescue OpenRouter::Catalog::Error => error
          error
        end
        caller_a.report_on_exception = false
        paused.pop(timeout: 5) || flunk("#{outcome}: caller A never reached its cache miss (#{finished_value(caller_a).inspect})")

        result_b = begin
          OpenRouter::Catalog.new(transport:, cache: store).call
        rescue OpenRouter::Catalog::Error => error
          error
        end
        resume << true
        caller_a.join(5) || flunk("#{outcome}: caller A did not finish")

        assert_equal 1, calls, "#{outcome}: caller A must not fetch again"
        if outcome == :success
          assert_equal [ 1, 1 ], [ caller_a.value, result_b ].map { it.models.size }
        else
          assert_instance_of OpenRouter::Catalog::Error, caller_a.value
          assert_instance_of OpenRouter::Catalog::Error, result_b
        end
        assert_nil OpenRouter::Catalog.landed, "no landed outcome outlives its callers"

        failing = false
        expiry = outcome == :success ? OpenRouter::Catalog::CACHE_TTL : OpenRouter::Catalog::FAILURE_BACKOFF
        travel expiry + 1.second do
          assert_equal 1, OpenRouter::Catalog.new(transport:, cache: store).call.models.size
        end
        assert_equal 2, calls, "#{outcome}: the next request after expiry fetches normally"
      end
    end

    # Answers the failure-marker read with the value seen before pausing.
    class StaleMissCache < SimpleDelegator
      def initialize(cache, paused:, resume:)
        super(cache)
        @paused = paused
        @resume = resume
      end

      def read(key, **options)
        value = super
        if key == OpenRouter::Catalog::FAILURE_CACHE_KEY
          @paused << true
          @resume.pop(timeout: 5) || raise("caller A was never resumed")
        end
        value
      end
    end

    # A loopback HTTP server that answers each connection with a scripted
    # handler, so transport timing is tested without any external network.
    class ScriptedServer
      attr_reader :connections

      def initialize(handler)
        @server = TCPServer.new("127.0.0.1", 0)
        @connections = 0
        @handlers = []
        @acceptor = Thread.new do
          loop do
            client = @server.accept
            @connections += 1
            @handlers << Thread.new(client) do |socket|
              handler.call(socket)
            rescue IOError, SystemCallError
              nil
            ensure
              socket.close
            end
          end
        rescue IOError
          nil
        end
      end

      def endpoint(scheme: "http")
        URI("#{scheme}://127.0.0.1:#{@server.addr[1]}/api/v1/models")
      end

      def close
        @server.close
        @acceptor.join(2)
        @handlers.each { it.join(10) }
      end
    end

    # The same composition as SolidCache::Store in production: entries are read
    # through read_serialized_entry with Strategy::LocalCache prepended.
    class LocalCachedFileStore < ActiveSupport::Cache::FileStore
      prepend ActiveSupport::Cache::Strategy::LocalCache
    end

    private

    def with_server(handler)
      server = ScriptedServer.new(handler)
      yield server
    ensure
      server&.close
    end

    # Reads the request, then sends headers and the body in timed chunks.
    def respond(socket, body, status: "200 OK", headers_after: 0, every: 0, chunks: 1)
      socket.gets("\r\n\r\n")
      pause(socket, headers_after)
      socket.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
                   "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n")
      body.bytes.each_slice((body.bytesize / chunks.to_f).ceil) do |slice|
        pause(socket, every)
        socket.write(slice.pack("C*"))
      end
    end

    # Waits, but stops the handler as soon as the client hangs up.
    def pause(socket, seconds)
      raise IOError, "client closed" if seconds.positive? && socket.wait_readable(seconds)
    end

    def assert_aborted_near_deadline(endpoint)
      catalog = OpenRouter::Catalog.new(cache: memory_cache, endpoint:, total_timeout: 1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      assert_raises(OpenRouter::Catalog::Error) { catalog.call }
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :>=, 0.9
      assert_operator elapsed, :<, 1.6, "aborted after #{elapsed.round(2)}s against a 1s total deadline"
    end

    # Runs count callers at once, each inside its own request-local cache.
    # With gated:, the transport holds the first fetch until a caller has
    # reached it, and fails fast if none does.
    def run_callers(count, cache:, gated: nil, **options)
      reached = gated&.size
      @release&.clear
      threads = Array.new(count) do
        Thread.new do
          cache.with_local_cache do
            OpenRouter::Catalog.new(cache:, clock: -> { Time.current }, **options).call
          end
        rescue OpenRouter::Catalog::Error => error
          error
        end.tap { it.report_on_exception = false }
      end
      if gated
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.01 while gated.size == reached && threads.any?(&:alive?) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        if gated.size == reached
          flunk "no caller reached the transport (waited at most 5s); callers that finished returned " \
                "#{threads.reject(&:alive?).map { finished_value(it) }.inspect}"
        end
        count.times { @release << true }
      end
      threads.map do |thread|
        thread.join(10) || flunk("a catalog caller did not finish within 10s")
        thread.value
      end
    end

    def gated_transport(upstream, &failing)
      @release = Queue.new
      lambda do
        upstream << true
        @release.pop(timeout: 5) || raise("the transport was never released")
        raise Net::ReadTimeout, "upstream down" if failing.call

        catalog_body
      end
    end

    def finished_value(thread)
      return :still_running if thread.alive?

      thread.value
    rescue Exception => error # rubocop:disable Lint/RescueException
      error
    end

    def catalog_body
      JSON.generate("data" => [ model_entry ])
    end

    def memory_cache
      ActiveSupport::Cache::MemoryStore.new
    end

    def build_catalog(entry)
      OpenRouter::Catalog.new(transport: -> { JSON.generate("data" => [ entry ]) }, cache: memory_cache)
    end

    def model_entry
      {
        "id" => "anthropic/claude-3.5-haiku",
        "name" => "Anthropic: Claude 3.5 Haiku",
        "context_length" => 200_000,
        "architecture" => {
          "input_modalities" => [ "text", "image" ],
          "output_modalities" => [ "text" ]
        },
        "top_provider" => { "max_completion_tokens" => 8_192 },
        "pricing" => { "prompt" => "0.0000008", "completion" => "0.000004" },
        "supported_parameters" => [ "max_tokens", "response_format", "structured_outputs" ]
      }
    end
  end
end
