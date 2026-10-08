module SourceImports
  class PdfExtractor
    # Counts the PDF workers this process runs at once and admits a new one
    # only while fewer than `limit` are active. Each worker may grow to
    # PdfExtractor::MEMORY_LIMIT_BYTES, so the limit bounds their combined
    # memory no matter how many requests arrive together.
    #
    # A caller waits at most `wait_seconds` for a slot and is otherwise told
    # the extractor is busy, so waiting uploads cannot hold every web thread
    # for a full parse. A slot is returned however the work ends, including
    # an exception or an asynchronous interrupt such as Thread#raise.
    class WorkerSlots
      attr_reader :limit, :wait_seconds

      def initialize(limit:, wait_seconds:)
        raise ArgumentError, "limit must be positive" unless limit.positive?

        @limit = limit
        @wait_seconds = wait_seconds
        @active = 0
        @mutex = Mutex.new
        @released = ConditionVariable.new
      end

      # Yields while holding a slot, or raises Busy if none frees in time.
      # Interrupts are deferred while a slot is taken or returned, so one
      # cannot arrive between taking a slot and the ensure that returns it.
      def hold
        Thread.handle_interrupt(Object => :never) do
          raise Busy.new("pdf_busy", MESSAGES.fetch("pdf_busy")) unless acquire

          begin
            Thread.handle_interrupt(Object => :immediate) { yield }
          ensure
            release
          end
        end
      end

      def active
        @mutex.synchronize { @active }
      end

      private

      def acquire
        deadline = monotonic_now + wait_seconds
        @mutex.synchronize do
          while @active >= limit
            remaining = deadline - monotonic_now
            return false unless remaining.positive?

            @released.wait(@mutex, remaining)
          end
          @active += 1
          true
        end
      end

      def release
        @mutex.synchronize do
          @active -= 1
          @released.signal
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
