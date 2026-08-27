require "test_helper"
require_relative "../../support/analytics_test_helper"

class History::ExperimentQueryTest < ActiveSupport::TestCase
  include AnalyticsTestHelper

  test "orders newest first paginates and validates page safely" do
    model = create_analytics_model(name: "History pagination model")
    created = 27.times.map do |index|
      experiment, = create_analytics_experiment(name: "History page #{index}", models: [ model ])
      experiment.update_columns(created_at: Time.utc(2030, 1, 1) + index.minutes)
      experiment
    end

    first_page = History::ExperimentQuery.new(experiment_scope: Experiment.all, page: "not-a-number").call
    second_page = History::ExperimentQuery.new(experiment_scope: Experiment.all, page: 2).call
    oversized_page = History::ExperimentQuery.new(experiment_scope: Experiment.all, page: 99_999).call

    assert_equal 1, first_page.current_page
    assert_equal 25, first_page.entries.size
    assert_equal created.last, first_page.entries.first.experiment
    assert first_page.entries.first.experiment.created_at >= first_page.entries.last.experiment.created_at
    assert_equal first_page.total_pages, oversized_page.current_page
    assert_equal first_page.total_count - 25, second_page.entries.size
  end

  test "adds each run cost once despite multiple evaluations" do
    candidate = create_analytics_model(name: "History cost candidate")
    other = create_analytics_model(name: "History cost other")
    reviewers = 3.times.map { |index| create_analytics_model(name: "History reviewer #{index}") }
    judges = 2.times.map { |index| create_analytics_model(name: "History judge #{index}") }
    experiment, runs = create_analytics_experiment(
      name: "Exact history cost",
      models: [ candidate, other ],
      run_attributes: {
        candidate => { cost: BigDecimal("0.01") },
        other => { cost: BigDecimal("0.02") }
      }
    )
    review_round = create_review_round_with_runs(
      experiment: experiment,
      specs: reviewers.map do |reviewer|
        { reviewer: reviewer, scores: { runs[candidate] => 9, runs[other] => 8 }, cost: BigDecimal("0.01") }
      end
    )
    create_judge_round_with_runs(
      review_round: review_round,
      specs: judges.map do |judge|
        { judge: judge, scores: { runs[candidate] => 90, runs[other] => 80 }, cost: BigDecimal("0.02") }
      end,
      winner: runs[candidate]
    )

    entry = query_entry(experiment)

    assert_equal BigDecimal("0.10"), entry.known_system_cost
    assert_equal 7, entry.cost_sample_count
    assert_equal 7, entry.cost_record_count
    assert entry.cost_telemetry_complete?
    assert_equal 2, entry.translation_candidate_count
  end

  test "adds each finalization run cost once despite multiple proposals and versions" do
    candidate = create_analytics_model(name: "Finalization cost candidate")
    other = create_analytics_model(name: "Finalization cost opponent")
    reviewers = 3.times.map { |index| create_analytics_model(name: "Finalization reviewer #{index}") }
    judges = 2.times.map { |index| create_analytics_model(name: "Finalization judge #{index}") }
    finalizers = 2.times.map { |index| create_analytics_model(name: "Finalizer #{index}") }
    experiment, runs = create_analytics_experiment(
      name: "Finalization system cost",
      models: [ candidate, other ],
      run_attributes: {
        candidate => { cost: BigDecimal("0.01") },
        other => { cost: BigDecimal("0.02") }
      }
    )
    review_round = create_review_round_with_runs(
      experiment: experiment,
      specs: reviewers.map do |reviewer|
        { reviewer: reviewer, scores: { runs[candidate] => 9, runs[other] => 8 }, cost: BigDecimal("0.01") }
      end
    )
    judge_round = create_judge_round_with_runs(
      review_round: review_round,
      specs: judges.map do |judge|
        { judge: judge, scores: { runs[candidate] => 90, runs[other] => 80 }, cost: BigDecimal("0.02") }
      end,
      winner: runs[candidate]
    )
    final_translation, finalization_runs = create_finalization_history(
      judge_round: judge_round,
      specs: [
        { finalizer: finalizers.first, cost: BigDecimal("0.03"), status: :completed },
        { finalizer: finalizers.second, cost: BigDecimal("0.04"), status: :failed }
      ]
    )
    applied = Finalizations::ApplyProposal.call(
      final_translation: final_translation,
      finalization_run_id: finalization_runs.first.id
    )
    manual = FinalTranslations::SaveRevision.call(
      final_translation: final_translation,
      content: "Human revision after proposal",
      expected_version_number: applied.version_number
    )
    FinalTranslations::RestoreRevision.call(
      final_translation: final_translation,
      version_id: final_translation.versions.find_by!(version_number: 1).id,
      expected_version_number: manual.version_number
    )

    entry = query_entry(experiment)

    assert_equal BigDecimal("0.17"), entry.known_system_cost
    assert_equal 9, entry.cost_sample_count
    assert_equal 9, entry.cost_record_count
    assert entry.cost_telemetry_complete?
    assert_equal 4, final_translation.versions.count
    assert finalization_runs.second.failed?
  end

  test "null finalization cost marks otherwise known telemetry incomplete" do
    candidate = create_analytics_model(name: "Partial finalization candidate")
    reviewer = create_analytics_model(name: "Partial finalization reviewer")
    judge = create_analytics_model(name: "Partial finalization judge")
    finalizers = 2.times.map { |index| create_analytics_model(name: "Partial finalizer #{index}") }
    experiment, runs = create_analytics_experiment(
      name: "Partial finalization telemetry",
      models: [ candidate ],
      run_attributes: { candidate => { cost: BigDecimal("0.01") } }
    )
    review_round = create_review_round_with_runs(
      experiment: experiment,
      specs: [ { reviewer: reviewer, scores: { runs[candidate] => 8 }, cost: BigDecimal("0.02") } ]
    )
    judge_round = create_judge_round_with_runs(
      review_round: review_round,
      specs: [ { judge: judge, scores: { runs[candidate] => 90 }, cost: BigDecimal("0.03") } ],
      winner: runs[candidate]
    )
    create_finalization_history(
      judge_round: judge_round,
      specs: [
        { finalizer: finalizers.first, cost: BigDecimal("0.04"), status: :completed },
        { finalizer: finalizers.second, cost: nil, status: :failed }
      ]
    )

    entry = query_entry(experiment)

    assert_equal BigDecimal("0.10"), entry.known_system_cost
    assert_equal 4, entry.cost_sample_count
    assert_equal 5, entry.cost_record_count
    assert entry.cost_telemetry_incomplete?
  end

  test "all-null finalization telemetry is not converted to zero" do
    candidate = create_analytics_model(name: "Null finalization candidate")
    reviewer = create_analytics_model(name: "Null finalization reviewer")
    judge = create_analytics_model(name: "Null finalization judge")
    finalizers = 2.times.map { |index| create_analytics_model(name: "Null finalizer #{index}") }
    experiment, runs = create_analytics_experiment(
      name: "All-null finalization telemetry",
      models: [ candidate ],
      run_attributes: { candidate => { cost: nil } }
    )
    review_round = create_review_round_with_runs(
      experiment: experiment,
      specs: [ { reviewer: reviewer, scores: { runs[candidate] => 8 }, cost: nil } ]
    )
    judge_round = create_judge_round_with_runs(
      review_round: review_round,
      specs: [ { judge: judge, scores: { runs[candidate] => 90 }, cost: nil } ],
      winner: runs[candidate]
    )
    create_finalization_history(
      judge_round: judge_round,
      specs: [
        { finalizer: finalizers.first, cost: nil, status: :completed },
        { finalizer: finalizers.second, cost: nil, status: :failed }
      ]
    )

    entry = query_entry(experiment)

    assert_nil entry.known_system_cost
    assert_equal 0, entry.cost_sample_count
    assert_equal 5, entry.cost_record_count
    assert entry.cost_telemetry_incomplete?
  end

  test "reports known partial total and does not turn missing costs into zero" do
    candidate = create_analytics_model(name: "Partial cost candidate")
    reviewer = create_analytics_model(name: "Partial cost reviewer")
    experiment, runs = create_analytics_experiment(
      name: "Partial telemetry",
      models: [ candidate ],
      run_attributes: { candidate => { cost: nil } }
    )
    create_review_round_with_runs(
      experiment: experiment,
      specs: [ { reviewer: reviewer, scores: { runs[candidate] => 8 }, cost: BigDecimal("0.02") } ]
    )

    entry = query_entry(experiment)

    assert_equal BigDecimal("0.02"), entry.known_system_cost
    assert_equal 1, entry.cost_sample_count
    assert_equal 2, entry.cost_record_count
    assert entry.cost_telemetry_incomplete?
  end

  test "returns no total when every run cost is missing" do
    candidate = create_analytics_model(name: "No known cost candidate")
    experiment, = create_analytics_experiment(
      name: "No known costs",
      models: [ candidate ],
      run_attributes: { candidate => { cost: nil } }
    )

    entry = query_entry(experiment)

    assert_nil entry.known_system_cost
    assert_equal 0, entry.cost_sample_count
    assert_equal 1, entry.cost_record_count
    assert entry.cost_telemetry_incomplete?
  end

  private

  def query_entry(experiment)
    History::ExperimentQuery.new(experiment_scope: Experiment.all).call.entries.find do |entry|
      entry.experiment.id == experiment.id
    end
  end


  def create_finalization_history(judge_round:, specs:)
    final_translation = FinalTranslations::Create.call(judge_round: judge_round)
    round = final_translation.finalization_rounds.create!(
      base_version: final_translation.current_version,
      selection_key: SecureRandom.hex(32)
    )
    runs = specs.map do |spec|
      run = round.finalization_runs.create!(
        finalizer_llm_model: spec.fetch(:finalizer),
        cost: spec[:cost]
      )
      if spec.fetch(:status).to_s == "completed"
        run.update!(
          status: :completed,
          proposed_translation: "Proposal by #{spec.fetch(:finalizer).display_name}",
          change_summary: [ "Refined wording" ],
          terminology_notes: [],
          warnings: [],
          completed_at: Time.current
        )
      else
        run.update!(
          status: spec.fetch(:status),
          error_code: "provider_failed",
          error_message: "Provider failed after billable work",
          completed_at: Time.current
        )
      end
      run
    end
    Finalizations::ReconcileRound.call(round)
    [ final_translation, runs ]
  end
end
