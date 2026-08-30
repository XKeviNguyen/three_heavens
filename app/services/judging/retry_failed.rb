module Judging
  class RetryFailed
    JUDGE_OUTPUT_ATTRIBUTES = %i[rank overall_score rationale strengths risks].freeze

    def self.call(judge_round)
      if judge_round.judge_runs.failed.any?(&:segmented?)
        return Ai::RetryFailedSegmentRuns.call(
          parent: judge_round,
          logical_runs_association: :judge_runs,
          child_runs_association: :judge_segment_runs,
          model_association: :judge_llm_model,
          job_class: JudgeSegmentRunJob,
          prepare_parent: lambda do |parent, _|
            parent.update!(status: :running, winner_translation_run: nil, aggregate_rankings: [], aggregation_explanation: nil)
          end,
          prepare_logical: lambda do |run|
            run.judge_evaluations.update_all(JUDGE_OUTPUT_ATTRIBUTES.index_with(nil))
            run.assign_attributes(winner_translation_run: nil, winner_rationale: nil, confidence_score: nil)
          end,
          prepare_child: ->(run) { run.assign_attributes(judgment: {}) }
        )
      end

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
