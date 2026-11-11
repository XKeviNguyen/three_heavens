require "test_helper"

# The database, not only the services that write runs, ties a run's status to
# its completion time and keeps experiment and translation run statuses to
# the known set (20261111090000).
class RunLifecycleConstraintsTest < ActiveSupport::TestCase
  RUN_TABLES = %w[
    translation_runs translation_segment_runs
    review_runs review_segment_runs
    judge_runs judge_segment_runs
    finalization_runs finalization_segment_runs
  ].freeze

  test "every run table enforces status and completion time together" do
    RUN_TABLES.each do |table|
      completion = check_definition(table, "#{table}_completion_check")
      assert_match(/'completed'.*'failed'.*completed_at IS NOT NULL/, completion, table)
    end
  end

  test "a finished run needs a completion time and an unfinished one has none" do
    run = translation_runs(:one)

    assert_violates { run.update_columns(status: "completed", completed_at: nil) }
    assert_violates { run.update_columns(status: "failed", completed_at: nil) }
    assert_violates { run.update_columns(status: "running", completed_at: Time.current) }

    run.update_columns(status: "failed", completed_at: Time.current)
    run.update_columns(status: "pending", completed_at: nil)
    assert run.reload.pending?
  end

  test "translation run and experiment statuses are limited to the known set" do
    assert_violates { translation_runs(:one).update_columns(status: "cancelled") }
    assert_violates { experiments(:one).update_columns(status: "cancelled") }
  end

  private

  def check_definition(table, name)
    ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid = '#{table}'::regclass AND conname = '#{name}' AND convalidated
    SQL
  end

  def assert_violates(&block)
    assert_raises(ActiveRecord::CheckViolation) { ActiveRecord::Base.transaction(requires_new: true, &block) }
  end
end
