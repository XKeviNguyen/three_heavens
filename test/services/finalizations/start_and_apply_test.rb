require "test_helper"
require_relative "../../support/final_translation_test_helper"

class Finalizations::StartAndApplyTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper

  setup do
    @final_translation = create_final_translation_workspace
    @finalizers = [ create_finalizer, create_finalizer ]
  end

  test "starts one or multiple finalizers against the exact base and enqueues after commit" do
    base = @final_translation.current_version
    assert_enqueued_jobs 2, only: FinalizationRunJob do
      @round = Finalizations::Start.call(
        final_translation: @final_translation,
        finalizer_ids: @finalizers.map(&:id)
      )
    end

    assert @round.running?
    assert_equal base, @round.base_version
    assert_equal @finalizers.map(&:id).sort,
                 @round.finalization_runs.pluck(:finalizer_llm_model_id).sort
    assert FinalizationRunJob.enqueue_after_transaction_commit
  end

  test "rejects duplicate IDs instead of silently changing the selection" do
    assert_no_difference [ -> { FinalizationRound.count }, -> { FinalizationRun.count } ] do
      assert_no_enqueued_jobs only: FinalizationRunJob do
        assert_raises FinalTranslations::InvalidSelectionError do
          Finalizations::Start.call(
            final_translation: @final_translation,
            finalizer_ids: [ @finalizers.first.id, @finalizers.first.id ]
          )
        end
      end
    end

    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizers.first.id ]
    )
    assert round.running?
    assert_raises FinalTranslations::ActiveRoundError do
      Finalizations::Start.call(
        final_translation: @final_translation,
        finalizer_ids: @finalizers.map(&:id)
      )
    end
  end

  test "rejects every malformed nonexistent inactive unsupported and mixed selection" do
    inactive = create_finalizer(active: false)
    direct = create_finalizer(gateway: "direct")
    [ [], [ "bad" ], [ 99_999_999 ], [ inactive.id ], [ direct.id ],
      [ @finalizers.first.id, inactive.id ] ].each do |ids|
      assert_no_difference [ -> { FinalizationRound.count }, -> { FinalizationRun.count } ] do
        assert_raises FinalTranslations::InvalidSelectionError do
          Finalizations::Start.call(final_translation: @final_translation, finalizer_ids: ids)
        end
      end
    end
  end

  test "allows a new round after terminal state and preserves immutable old base" do
    first = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizers.first.id ]
    )
    clear_enqueued_jobs
    old_base = first.base_version
    complete_finalization_run(first.finalization_runs.first)
    FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: "New human draft",
      expected_version_number: old_base.version_number
    )

    second = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizers.second.id ]
    )
    clear_enqueued_jobs
    assert_equal old_base, first.reload.base_version
    assert_equal @final_translation.current_version, second.base_version
    assert_not_equal first, second
  end

  test "editing does not retarget an active round and another active round remains blocked" do
    round = Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizers.first.id ]
    )
    clear_enqueued_jobs
    base = round.base_version
    FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: "Manual edit while AI runs",
      expected_version_number: base.version_number
    )

    assert_equal base, round.reload.base_version
    assert_raises FinalTranslations::ActiveRoundError do
      Finalizations::Start.call(
        final_translation: @final_translation,
        finalizer_ids: [ @finalizers.second.id ]
      )
    end
  end

  test "finalized workspace rejects refinement and enqueue failures become retryable failures" do
    FinalTranslations::ChangeStatus.finalize(final_translation: @final_translation)
    assert_raises FinalTranslations::InvalidStateError do
      Finalizations::Start.call(
        final_translation: @final_translation,
        finalizer_ids: [ @finalizers.first.id ]
      )
    end
    FinalTranslations::ChangeStatus.reopen(final_translation: @final_translation)

    failing_job = Class.new do
      attr_reader :job_id

      def initialize(*)
        @job_id = SecureRandom.uuid
      end

      def enqueue
        raise SolidQueue::Job::EnqueueError, "private queue database detail"
      end
    end
    assert_no_enqueued_jobs only: FinalizationRunJob do
      round = Finalizations::Start.new(
        final_translation: @final_translation,
        finalizer_ids: [ @finalizers.first.id ],
        job_class: failing_job
      ).call
      run = round.finalization_runs.first

      assert round.reload.failed?
      assert run.reload.failed?
      assert_equal "enqueue_failed", run.error_code
      assert_equal Ai::RunScheduler::ERROR_MESSAGE, run.error_message
      assert_not_includes run.error_message, "private queue database detail"
    end
  end

  test "applies completed proposal explicitly as one audited immutable version" do
    round = start_round
    run = complete_finalization_run(round.finalization_runs.first)
    base = round.base_version

    assert_difference -> { FinalTranslationVersion.count }, 1 do
      @applied = Finalizations::ApplyProposal.call(
        final_translation: @final_translation,
        finalization_run_id: run.id
      )
    end
    assert @applied.ai_applied?
    assert_equal run, @applied.source_finalization_run
    assert_equal run.proposed_translation, @applied.content
    assert_equal @applied, @final_translation.reload.current_version
    assert_equal base.content, base.reload.content

    assert_no_difference -> { FinalTranslationVersion.count } do
      assert_equal @applied, Finalizations::ApplyProposal.call(
        final_translation: @final_translation,
        finalization_run_id: run.id
      )
    end
  end

  test "rejects pending failed foreign stale and finalized proposal application" do
    round = start_round
    run = round.finalization_runs.first
    assert_raises FinalTranslations::InvalidProposalError do
      apply(run)
    end
    run.update!(status: :failed, completed_at: Time.current)
    assert_raises FinalTranslations::InvalidProposalError do
      apply(run)
    end

    other = create_final_translation_workspace
    assert_raises ActiveRecord::RecordNotFound do
      Finalizations::ApplyProposal.call(
        final_translation: other,
        finalization_run_id: run.id
      )
    end

    run.update_columns(
      status: "completed",
      proposed_translation: "Valid proposal",
      change_summary: [],
      terminology_notes: [],
      warnings: []
    )
    FinalTranslations::SaveRevision.call(
      final_translation: @final_translation,
      content: "New manual text",
      expected_version_number: round.base_version.version_number
    )
    assert_raises FinalTranslations::StaleVersionError do
      apply(run)
    end

    finalized_workspace = create_final_translation_workspace
    finalized_finalizer = create_finalizer
    finalized_round = Finalizations::Start.call(
      final_translation: finalized_workspace,
      finalizer_ids: [ finalized_finalizer.id ]
    )
    clear_enqueued_jobs
    finalized_run = complete_finalization_run(finalized_round.finalization_runs.first)
    FinalTranslations::ChangeStatus.finalize(final_translation: finalized_workspace)
    assert_raises FinalTranslations::InvalidStateError do
      Finalizations::ApplyProposal.call(
        final_translation: finalized_workspace,
        finalization_run_id: finalized_run.id
      )
    end
  end

  private

  def start_round
    Finalizations::Start.call(
      final_translation: @final_translation,
      finalizer_ids: [ @finalizers.first.id ]
    ).tap { clear_enqueued_jobs }
  end

  def apply(run)
    Finalizations::ApplyProposal.call(
      final_translation: @final_translation,
      finalization_run_id: run.id
    )
  end
end
