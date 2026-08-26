require "test_helper"
require_relative "../../support/judging_test_helper"

class Judging::AggregateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include JudgingTestHelper

  setup do
    @review_round = create_completed_review_round
    @judges = [ create_judge_model, create_judge_model ]
    @judge_round = Judging::Start.call(
      review_round: @review_round,
      judge_ids: @judges.map(&:id)
    )
    clear_enqueued_jobs
  end

  test "multiple judges use Borda consensus before mean score" do
    runs = @judge_round.judge_runs.to_a
    target = @review_round.experiment.translation_runs.first
    runs.each do |run|
      target_label = run.judge_evaluations.find_by!(translation_run: target).anonymous_label
      other_label = (run.judge_evaluations.pluck(:anonymous_label) - [ target_label ]).sole
      complete_judge_run(run, order: [ target_label, other_label ])
    end

    Judging::ReconcileRound.call(@judge_round)

    assert @judge_round.reload.completed?
    assert_equal target, @judge_round.winner_translation_run
    assert_operator @judge_round.aggregate_rankings.first.fetch("borda_points"),
                    :>,
                    @judge_round.aggregate_rankings.second.fetch("borda_points")
  end

  test "equal Borda points use higher mean score before translation ID" do
    lower_id_translation, higher_id_translation =
      @review_round.experiment.translation_runs.order(:id).to_a
    first_run, second_run = @judge_round.judge_runs.order(:id).to_a
    first_labels = labels_for(first_run, lower_id_translation, higher_id_translation)
    second_labels = labels_for(second_run, higher_id_translation, lower_id_translation)
    complete_judge_run(
      first_run,
      order: first_labels,
      scores: { first_labels[0] => 90, first_labels[1] => 80 }
    )
    complete_judge_run(
      second_run,
      order: second_labels,
      scores: { second_labels[0] => 100, second_labels[1] => 60 }
    )

    Judging::ReconcileRound.call(@judge_round)

    rankings = @judge_round.reload.aggregate_rankings
    assert_equal rankings[0]["borda_points"], rankings[1]["borda_points"]
    assert_operator rankings[0]["mean_overall_score"],
                    :>,
                    rankings[1]["mean_overall_score"]
    assert_equal higher_id_translation, @judge_round.winner_translation_run
    assert_operator higher_id_translation.id, :>, lower_id_translation.id
  end

  test "equal Borda points and mean score use stable translation ID tie-break" do
    first_translation, second_translation = @review_round.experiment.translation_runs.order(:id).to_a
    first_run, second_run = @judge_round.judge_runs.order(:id).to_a
    first_labels = labels_for(first_run, first_translation, second_translation)
    second_labels = labels_for(second_run, second_translation, first_translation)
    complete_judge_run(
      first_run,
      order: first_labels,
      scores: { first_labels[0] => 90, first_labels[1] => 80 }
    )
    complete_judge_run(
      second_run,
      order: second_labels,
      scores: { second_labels[0] => 90, second_labels[1] => 80 }
    )

    Judging::ReconcileRound.call(@judge_round)

    rankings = @judge_round.reload.aggregate_rankings
    assert_equal rankings[0]["borda_points"], rankings[1]["borda_points"]
    assert_equal rankings[0]["mean_overall_score"], rankings[1]["mean_overall_score"]
    assert_equal first_translation, @judge_round.winner_translation_run
    assert_includes @judge_round.aggregation_explanation, "TranslationRun ID ascending"
  end

  private

  def labels_for(run, first_translation, second_translation)
    [ first_translation, second_translation ].map do |translation|
      run.judge_evaluations.find_by!(translation_run: translation).anonymous_label
    end
  end
end
