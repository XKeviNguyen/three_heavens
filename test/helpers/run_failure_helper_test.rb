require "test_helper"

class RunFailureHelperTest < ActionView::TestCase
  include ApplicationHelper

  Part = Data.define(:id, :error_code) do
    def failed? = error_code.present?
  end
  WholeRun = Data.define(:error_code)
  SegmentedRun = Data.define(:error_code, :translation_segment_runs)

  test "a segmented failure shows the first failed part's own reason" do
    run = SegmentedRun.new(
      error_code: "segment_execution_failed",
      translation_segment_runs: [ Part.new(id: 3, error_code: nil), Part.new(id: 9, error_code: "http_429"), Part.new(id: 5, error_code: "http_402") ]
    )

    assert_equal "http_402", run_failure_code(run)
    assert_equal I18n.t("results_ui.failure_reasons.http_402"), run_failure_explanation(run)
  end

  test "app-defined codes are shown; anything else stays generic" do
    assert_equal "incomplete_response", run_failure_code(WholeRun.new(error_code: "incomplete_response"))
    assert_equal I18n.t("results_ui.failure_reasons.incomplete_response"), run_failure_explanation(WholeRun.new(error_code: "incomplete_response"))
    assert_equal "provider_failure", run_failure_code(WholeRun.new(error_code: "Provider said: sk-or-v1-secret"))
    assert_equal I18n.t("results_ui.provider_failure"), run_failure_explanation(WholeRun.new(error_code: "http_418"))
    assert_equal "segment_execution_failed", run_failure_code(SegmentedRun.new(error_code: "segment_execution_failed", translation_segment_runs: []))
  end
end
