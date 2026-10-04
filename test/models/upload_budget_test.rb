require "test_helper"
require_relative "../support/process_barrier"
require_relative "../support/upload_budget_clock"

class UploadBudgetTest < ActiveSupport::TestCase
  include ProcessBarrier
  include UploadBudgetClock
  self.use_transactional_tests = false

  setup do
    @user = users(:normal)
    UploadBudget.where(user: [ @user, users(:other) ]).delete_all
  end

  teardown { UploadBudget.where(user: [ @user, users(:other) ]).delete_all }

  test "simultaneous first consumes admit exactly the limit across independent processes" do
    assert_nil UploadBudget.find_by(user: @user)
    results = in_processes(32) { UploadBudget.consume(user: @user) }
    receipts = results.compact
    assert_equal SourceImports::Limits::UPLOADS_PER_WINDOW, receipts.size
    budget = UploadBudget.uncached { UploadBudget.find_by!(user: @user) }
    assert_equal receipts.size, budget.count
    assert_equal receipts.map(&:token).sort, budget.receipts.sort
    assert_nil UploadBudget.consume(user: @user), "limit + 1 must be rejected"
  end

  test "concurrent consume and duplicate refund preserve exactly the charged count" do
    initial = 5.times.map { UploadBudget.consume(user: @user) }
    results = in_processes(20) do |index|
      index.even? ? [ :refund, UploadBudget.refund(initial.first) ] : [ :consume, UploadBudget.consume(user: @user).present? ]
    end
    refunds = results.count { |kind, success| kind == :refund && success }
    consumes = results.count { |kind, success| kind == :consume && success }
    assert_equal 1, refunds
    budget = UploadBudget.find_by!(user: @user)
    assert_equal initial.size + consumes - refunds, budget.count
    assert_equal budget.count, budget.receipts.size
    assert_operator budget.count, :<=, SourceImports::Limits::UPLOADS_PER_WINDOW
  end

  test "a receipt can be refunded once across processes and never below zero" do
    receipt = UploadBudget.consume(user: @user)
    assert_equal 1, in_processes(16) { UploadBudget.refund(receipt) }.count(true)
    assert_equal 0, UploadBudget.find_by!(user: @user).count
    assert_not UploadBudget.refund(receipt)
    assert_not UploadBudget.refund(nil)
    assert_raises ActiveRecord::StatementInvalid do
      UploadBudget.where(user: @user).update_all(count: -1)
    end
  end

  test "expired refunds cannot change or resurrect a window and rollover replaces receipts" do
    current = UploadBudget.consume(user: @user)
    with_upload_budget_window(1_000_001) do
      assert_not UploadBudget.refund(current)
      assert_equal 1, UploadBudget.find_by!(user: @user).count
      fresh = UploadBudget.consume(user: @user)
      assert_equal current.window_id + 1, fresh.window_id
      assert_equal [ fresh.token ], UploadBudget.find_by!(user: @user).receipts
      assert_not UploadBudget.refund(current)
      assert_equal 1, UploadBudget.find_by!(user: @user).count
    end
  end

  test "separate accounts have independent budgets" do
    SourceImports::Limits::UPLOADS_PER_WINDOW.times { assert UploadBudget.consume(user: @user) }
    assert_nil UploadBudget.consume(user: @user)
    assert UploadBudget.consume(user: users(:other))
    assert_equal 1, UploadBudget.find_by!(user: users(:other)).count
  end
end
