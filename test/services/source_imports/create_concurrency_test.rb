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

    private

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
