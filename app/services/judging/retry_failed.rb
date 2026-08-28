module Judging
  class RetryFailed
    JUDGE_OUTPUT_ATTRIBUTES = %i[rank overall_score rationale strengths risks].freeze

    def self.call(judge_round)
      Ai::RetryFailedRuns.call(
        parent: judge_round,
        runs_association: :judge_runs,
        model_association: :judge_llm_model,
        job_class: JudgeRunJob,
        prepare_parent: lambda do |parent, _|
          parent.update!(
            status: :running,
            winner_translation_run: nil,
            aggregate_rankings: [],
            aggregation_explanation: nil
          )
        end,
        prepare_run: ->(run) { run.judge_evaluations.update_all(JUDGE_OUTPUT_ATTRIBUTES.index_with(nil)) }
      )
    end
  end
end
