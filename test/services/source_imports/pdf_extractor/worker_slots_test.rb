require "test_helper"

module SourceImports
  class PdfExtractor
    class WorkerSlotsTest < ActiveSupport::TestCase
      test "never admits more holders than the limit, however many threads ask at once" do
        slots = WorkerSlots.new(limit: 2, wait_seconds: 5)
        inside = Concurrent::AtomicFixnum.new
        most = Concurrent::AtomicFixnum.new

        6.times.map do
          Thread.new do
            slots.hold do
              current = inside.increment
              most.update { |value| [ value, current ].max }
              sleep 0.05
              inside.decrement
            end
          end
        end.each(&:join)

        assert_equal 2, most.value
        assert_equal 0, slots.active
      end

      test "a caller that cannot get a slot in time is told the extractor is busy" do
        slots = WorkerSlots.new(limit: 1, wait_seconds: 0.2)
        holding, finish = Queue.new, Queue.new
        holder = Thread.new { slots.hold { holding << true; finish.pop } }
        holding.pop
        started = monotonic_now

        error = assert_raises(Busy) { slots.hold { flunk "admitted beyond the limit" } }

        assert_equal "pdf_busy", error.code
        assert_kind_of Error, error
        assert_in_delta 0.2, monotonic_now - started, 0.15
        finish << true
        holder.join
        assert_equal 0, slots.active
      end

      test "a waiting caller is admitted as soon as a slot is returned" do
        slots = WorkerSlots.new(limit: 1, wait_seconds: 5)
        holding, finish = Queue.new, Queue.new
        holder = Thread.new { slots.hold { holding << true; finish.pop } }
        holding.pop
        waiter = Thread.new { slots.hold { :admitted } }
        sleep 0.05
        finish << true

        assert_equal :admitted, waiter.value
        holder.join
        assert_equal 0, slots.active
      end

      test "a slot is returned when the work raises" do
        slots = WorkerSlots.new(limit: 1, wait_seconds: 0)

        assert_raises(RuntimeError) { slots.hold { raise "worker failed" } }

        assert_equal 0, slots.active
        assert_equal :again, slots.hold { :again }
      end

      test "a slot is returned when the holding thread is interrupted or killed" do
        slots = WorkerSlots.new(limit: 1, wait_seconds: 0)
        [ ->(thread) { thread.raise(Interrupt) }, ->(thread) { thread.kill } ].each do |interrupt|
          holding = Queue.new
          thread = Thread.new { slots.hold { holding << true; sleep } }
          thread.report_on_exception = false
          holding.pop

          interrupt.call(thread)
          begin
            thread.join
          rescue Interrupt
            nil
          end

          assert_not thread.alive?
          assert_equal 0, slots.active
        end
      end

      # The interrupt is deferred until the bounded wait ends, so it can never
      # land between taking a slot and the ensure that returns it.
      test "an interrupted waiter takes no slot" do
        slots = WorkerSlots.new(limit: 1, wait_seconds: 0.3)
        holding, finish = Queue.new, Queue.new
        holder = Thread.new { slots.hold { holding << true; finish.pop } }
        holding.pop
        waiter = Thread.new { slots.hold { flunk "admitted after being interrupted" } }
        waiter.report_on_exception = false
        sleep 0.05

        waiter.raise(Interrupt)
        assert_raises(Interrupt) { waiter.join }
        finish << true
        holder.join

        assert_equal 0, slots.active
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
