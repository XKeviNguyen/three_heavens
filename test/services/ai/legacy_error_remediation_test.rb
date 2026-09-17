require "test_helper"

class Ai::LegacyErrorRemediationTest < ActiveSupport::TestCase
  test "remediation is bounded dry-run by default and never returns private contents" do
    run = translation_runs(:one)
    run.update_columns(
      status: "failed",
      error_code: "provider_failure",
      error_message: "Bearer PRIVATE_LEGACY_TOKEN provider body",
      completed_at: 2.days.ago,
      created_at: 3.days.ago,
      updated_at: 2.days.ago
    )

    preview = Ai::LegacyErrorRemediation.call(before: 1.day.ago, batch_size: 1)
    assert_equal 1, preview.candidate_count
    assert_equal 0, preview.remediated_count
    assert_not_includes preview.inspect, "PRIVATE_LEGACY_TOKEN"

    result = Ai::LegacyErrorRemediation.call(before: 1.day.ago, batch_size: 1, execute: true)
    assert_equal 1, result.remediated_count
    assert_equal Ai::LegacyErrorRemediation::SAFE_MESSAGE, run.reload.error_message
    assert_equal 0, Ai::LegacyErrorRemediation.call(before: 1.day.ago, execute: true).remediated_count
  end
end
