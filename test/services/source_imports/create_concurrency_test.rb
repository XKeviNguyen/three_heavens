require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class CreateConcurrencyTest < ActiveSupport::TestCase
    include DocumentIoTestHelper

    self.use_transactional_tests = false

    setup do
      @user = User.create!(
        email: "import-race-#{SecureRandom.hex(8)}@example.test",
        password: "import race password",
        role: :user,
        status: :active
      )
    end

    teardown do
      @user.source_imports.find_each(&:destroy!)
      UploadBudget.where(user: @user).delete_all
      @user.delete
    end

    test "simultaneous deliveries of one upload action store one import and one blob" do
      key = SecureRandom.hex(16)
      unattached_blobs = -> { ActiveStorage::Blob.where.missing(:attachments).count }
      unattached_before = unattached_blobs.call
      results = concurrently(3) do
        Create.call(user: @user, upload: uploaded_file("Concurrent source", filename: "race.txt"), request_key: key)
      end

      assert_empty results.grep(Exception), results.grep(Exception).map(&:full_message).join("\n")
      source_import = @user.source_imports.sole
      assert_equal [ source_import.id ], results.map(&:id).uniq
      assert_equal 1, ActiveStorage::Attachment.where(record: source_import).count
      assert source_import.source_file.blob.service.exist?(source_import.source_file.blob.key)
      assert_equal unattached_before, unattached_blobs.call
    end

    # Advisory locks are re-entrant within one database session, so whether a
    # busy delivery released its request lock is checked from other sessions.
    test "busy deliveries of one upload action store nothing and release the request lock" do
      key = SecureRandom.hex(16)
      upload = -> { uploaded_file(pdf_with_text("Busy then stored"), filename: "busy.pdf", content_type: "application/pdf") }
      holding, finish = Queue.new, Queue.new
      holder = Thread.new { PdfExtractor::WORKER_SLOTS.hold { holding << true; finish.pop } }
      holding.pop

      results = concurrently(2) { Create.call(user: @user, upload: upload.call, request_key: key) }
      finish << true
      holder.join

      assert_equal [ "pdf_busy", "pdf_busy" ], results.map { it.is_a?(Busy) ? it.code : it }
      assert_empty @user.source_imports.reload
      assert concurrently(1) { request_lock_free?(key) }.sole, "a busy delivery kept its request lock"
      assert concurrently(1) { Create.call(user: @user, upload: upload.call, request_key: key) }.sole.ready?
    ensure
      finish << true if holder&.alive?
      holder&.join
    end

    private

    def request_lock_free?(key)
      connection = ActiveRecord::Base.connection
      lock_key = RequestLock.key(user_id: @user.id, request_key: key)
      locked = connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_try_advisory_lock(?)", lock_key ]))
      connection.select_value(ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_unlock(?)", lock_key ])) if locked
      locked
    end

    def concurrently(count, &block)
      ready = Queue.new
      gate = Queue.new
      results = Queue.new
      threads = count.times.map do
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ready << true
            gate.pop
            results << block.call
          rescue StandardError => error
            results << error
          end
        end
      end
      count.times { ready.pop }
      count.times { gate << true }
      threads.each(&:join)
      count.times.map { results.pop }
    end
  end
end
