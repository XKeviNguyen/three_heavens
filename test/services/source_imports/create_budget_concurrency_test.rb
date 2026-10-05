require "test_helper"
require_relative "../../support/document_io_test_helper"
require_relative "../../support/process_barrier"
require_relative "../../support/upload_budget_clock"

module SourceImports
  class CreateBudgetConcurrencyTest < ActiveSupport::TestCase
    include DocumentIoTestHelper
    include ProcessBarrier
    include UploadBudgetClock
    self.use_transactional_tests = false

    setup do
      @user = User.create!(email: "action-race-#{SecureRandom.hex(8)}@example.test", password: "synthetic action password", role: :user, status: :active)
    end

    teardown do
      @user.source_imports.destroy_all
      UploadBudget.where(user: @user).delete_all
      @user.delete
    end

    test "twelve simultaneous processes share the tenth admission and its durable import" do
      9.times { UploadBudget.consume(user: @user) }
      key = SecureRandom.hex(16)
      results = in_processes(12) do
        result = Create.call(user: @user, request_key: key, upload: uploaded_file("Concurrent tenth", filename: "ten.txt"))
        [ result.id, result.source_file.blob_id ]
      end
      assert_equal 1, results.uniq.size
      source = @user.source_imports.sole
      assert source.source_file.blob.service.exist?(source.source_file.blob.key)
      assert_equal 1, ActiveStorage::Attachment.where(record: source).count
      budget = UploadBudget.find_by!(user: @user)
      assert_equal 10, budget.count
      assert_equal 10, budget.receipts.uniq.size
    end

    test "process loss at the tenth admission replays the interrupted action without another charge or extraction" do
      9.times { UploadBudget.consume(user: @user) }
      key = SecureRandom.hex(16)
      upload = -> { uploaded_file("Interrupted tenth", filename: "ten.txt") }
      crash_at_extraction { Create.call(user: @user, request_key: key, upload: upload.call) }
      assert @user.source_imports.sole.pending?
      assert_equal 10, UploadBudget.find_by!(user: @user).count
      error = assert_raises(Error) { Create.call(user: @user, request_key: key, upload: upload.call) }
      assert_equal "import_unavailable", error.code
      assert_equal 10, UploadBudget.find_by!(user: @user).count
      assert_equal 1, @user.source_imports.count
      assert_not @user.source_imports.sole.source_file.attached?
    end

    test "twelve different actions admit ten across processes" do
      results = in_processes(12) do
        Create.call(user: @user, request_key: SecureRandom.hex(16), upload: uploaded_file("Different action", filename: "same.txt"))
        :created
      rescue Create::RateLimited
        :limited
      end
      assert_equal({ created: 10, limited: 2 }, results.tally)
      assert_equal 10, @user.source_imports.count
      assert_equal 10, UploadBudget.find_by!(user: @user).count
    end
  end
end
