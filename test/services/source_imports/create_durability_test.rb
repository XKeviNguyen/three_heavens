require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  # A duplicate delivery of one upload action must never report success while
  # the first delivery's stored object is not yet durable, and every delivery
  # must converge on the first delivery's final outcome. The storage write is
  # held open after the database commit so the ordering is deterministic.
  class CreateDurabilityTest < ActiveSupport::TestCase
    include DocumentIoTestHelper

    self.use_transactional_tests = false

    setup do
      @user = User.create!(
        email: "import-durability-#{SecureRandom.hex(8)}@example.test",
        password: "import durability password",
        role: :user,
        status: :active
      )
      @key = SecureRandom.hex(16)
      @reached = Queue.new
      @decision = Queue.new
      reached = @reached
      decision = @decision
      ActiveStorage::Blob.service.define_singleton_method(:upload) do |*arguments, **options|
        reached << true
        raise IOError, "synthetic storage outage" if decision.pop == :fail

        super(*arguments, **options)
      end
    end

    teardown do
      singleton = ActiveStorage::Blob.service.singleton_class
      singleton.remove_method(:upload) if singleton.method_defined?(:upload, false)
      @threads&.each { |thread| thread.kill.join(5) }
      @user.source_imports.find_each(&:destroy!)
      @user.delete
    end

    test "a duplicate delivery waits for the stored object and converges on success" do
      winner = deliver
      assert @reached.pop(timeout: 10), "the first delivery never reached the storage write"
      replay = deliver
      assert_replay_waits(replay)

      source_import = @user.source_imports.sole
      assert_not source_import.ready?, "the import was ready before its object was stored"
      assert_not source_import.available?

      @decision << :succeed
      results = [ winner, replay ].map { |thread| thread.join(15)&.value }
      assert_empty results.grep(Exception), results.grep(Exception).map(&:full_message).join("\n")
      assert_equal [ source_import.id ], results.map(&:id).uniq
      source_import.reload
      assert source_import.available?
      assert source_import.source_file.blob.service.exist?(source_import.source_file.blob.key)
      assert_equal 1, ActiveStorage::Attachment.where(record: source_import).count
    end

    test "a duplicate delivery waits for the stored object and converges on the storage failure" do
      unattached_blobs = -> { ActiveStorage::Blob.where.missing(:attachments).count }
      blobs_before = ActiveStorage::Blob.count
      unattached_before = unattached_blobs.call

      winner = deliver
      assert @reached.pop(timeout: 10), "the first delivery never reached the storage write"
      replay = deliver
      assert_replay_waits(replay)

      @decision << :fail
      results = [ winner, replay ].map { |thread| thread.join(15)&.value }
      assert results.all?(Error), results.inspect
      assert_equal [ "storage_unavailable" ], results.map(&:code).uniq
      source_import = @user.source_imports.sole
      assert_equal [ source_import.id ], results.map { it.source_import.id }.uniq
      assert source_import.failed?
      assert_not source_import.source_file.attached?
      assert_equal [ blobs_before, unattached_before ], [ ActiveStorage::Blob.count, unattached_blobs.call ]

      later = assert_raises(Error) { create }
      assert_equal [ "storage_unavailable", source_import.id ], [ later.code, later.source_import.id ]
      @reached.clear
      Thread.new { @reached.pop(timeout: 10) && @decision << :succeed }
      assert create(request_key: SecureRandom.hex(16)).available?, "a new upload action must be able to succeed"
    end

    private

    def create(request_key: @key)
      Create.call(user: @user, upload: uploaded_file("Durable source", filename: "durable.txt"), request_key:)
    end

    def deliver
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection { create }
      rescue StandardError => error
        error
      end
      (@threads ||= []) << thread
      thread
    end

    # The replay has either finished or is blocked waiting for a database lock
    # held by the first delivery; it must not have finished.
    def assert_replay_waits(replay)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until !replay.alive? || waiting_lock_count.positive?
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "the replay neither finished nor waited for a lock:\n#{replay.backtrace&.first(12)&.join("\n")}"
        end
        sleep 0.01
      end
      # Lazy: evaluating replay.value would join the waiting replay.
      assert replay.alive?, -> { "the replay returned #{replay.value.inspect} before the stored object existed" }
    end

    # Uncached: the test executor's query cache would repeat the first answer.
    def waiting_lock_count
      ActiveRecord::Base.uncached do
        ActiveRecord::Base.connection.select_value(<<~SQL)
          SELECT count(*) FROM pg_locks
          WHERE NOT granted AND database = (SELECT oid FROM pg_database WHERE datname = current_database())
        SQL
      end
    end
  end
end
