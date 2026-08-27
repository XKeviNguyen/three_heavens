require_relative "judging_test_helper"

module FinalTranslationTestHelper
  include JudgingTestHelper

  def create_final_translation_workspace
    review_round = create_completed_review_round
    judge = create_judge_model
    judge_round = Judging::Start.call(
      review_round: review_round,
      judge_ids: [ judge.id ]
    )
    clear_enqueued_jobs if respond_to?(:clear_enqueued_jobs)
    complete_judge_run(judge_round.judge_runs.first)
    Judging::ReconcileRound.call(judge_round)
    FinalTranslations::Create.call(judge_round: judge_round)
  end

  def create_finalizer(suffix: SecureRandom.hex(4), active: true, gateway: "openrouter")
    LlmModel.create!(
      gateway: gateway,
      provider: "finalizer-provider-#{suffix}",
      model_identifier: "finalizer/#{suffix}",
      display_name: "Finalizer #{suffix}",
      active: active
    )
  end

  def complete_finalization_run(run, proposal: "Polished final translation")
    run.update!(
      status: :completed,
      proposed_translation: proposal,
      change_summary: [ "Improved clarity" ],
      terminology_notes: [ "Preserved theological term" ],
      warnings: [],
      completed_at: Time.current
    )
    Finalizations::ReconcileRound.call(run.finalization_round)
    run
  end
end
