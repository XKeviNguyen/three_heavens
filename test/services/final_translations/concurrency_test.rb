require "test_helper"
require_relative "../../support/final_translation_test_helper"

class FinalTranslations::ConcurrencyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  test "concurrent identical workspace creation produces one workspace" do
    review_round = create_completed_review_round
    judge = create_judge_model
    judge_round = Judging::Start.call(review_round: review_round, judge_ids: [ judge.id ])
    clear_enqueued_jobs
    complete_judge_run(judge_round.judge_runs.first)
    Judging::ReconcileRound.call(judge_round)

    results = concurrently(2) do
      FinalTranslations::Create.call(judge_round: JudgeRound.find(judge_round.id))
    end

    assert_empty results.grep(Exception)
    assert_equal 1, results.map(&:id).uniq.size
    assert_equal 1, FinalTranslation.where(judge_round: judge_round).count
    assert_equal 1, results.first.versions.count
  end

  test "concurrent manual saves serialize and reject one stale writer without lost updates" do
    final_translation = create_final_translation_workspace
    expected = final_translation.current_version.version_number

    results = concurrently(2) do |index|
      FinalTranslations::SaveRevision.call(
        final_translation: FinalTranslation.find(final_translation.id),
        content: "Concurrent draft #{index}",
        expected_version_number: expected
      )
    end

    assert_equal 1, results.grep(FinalTranslationVersion).size
    assert_equal 1, results.grep(FinalTranslations::StaleVersionError).size
    assert_equal 2, final_translation.versions.reload.count
    assert_equal 2, final_translation.reload.current_version.version_number
    assert_includes [ "Concurrent draft 0", "Concurrent draft 1" ],
                    final_translation.current_version.content
  end

  test "concurrent double proposal application creates one audited version" do
    final_translation = create_final_translation_workspace
    finalizer = create_finalizer
    round = Finalizations::Start.call(
      final_translation: final_translation,
      finalizer_ids: [ finalizer.id ]
    )
    clear_enqueued_jobs
    run = complete_finalization_run(round.finalization_runs.first)

    results = concurrently(2) do
      Finalizations::ApplyProposal.call(
        final_translation: FinalTranslation.find(final_translation.id),
        finalization_run_id: run.id
      )
    end

    assert_empty results.grep(Exception)
    assert_equal 1, results.map(&:id).uniq.size
    assert_equal 1, FinalTranslationVersion.where(source_finalization_run: run).count
    assert_equal 2, final_translation.versions.reload.count
  end

  test "concurrent identical refinement starts create one active round and one run" do
    final_translation = create_final_translation_workspace
    finalizer = create_finalizer

    results = concurrently(2) do
      Finalizations::Start.call(
        final_translation: FinalTranslation.find(final_translation.id),
        finalizer_ids: [ finalizer.id ]
      )
    end
    clear_enqueued_jobs

    assert_empty results.grep(Exception)
    assert_equal 1, results.map(&:id).uniq.size
    assert_equal 1, final_translation.finalization_rounds.reload.running.count
    assert_equal 1, results.first.finalization_runs.count
  end

  private

  def concurrently(count)
    ready = Queue.new
    gate = Queue.new
    results = Queue.new
    threads = count.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          gate.pop
          results << yield(index)
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
