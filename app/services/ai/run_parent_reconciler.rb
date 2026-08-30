module Ai
  class RunParentReconciler
    def self.call(run)
      case run
      when TranslationRun
        TranslationExperiments::ReconcileExperiment.call(run.experiment)
      when ReviewRun
        BlindReviews::ReconcileRound.call(run.review_round)
      when JudgeRun
        Judging::ReconcileRound.call(run.judge_round)
      when FinalizationRun
        Finalizations::ReconcileRound.call(run.finalization_round)
      when TranslationSegmentRun
        TranslationSegments::ReconcileRun.call(run.translation_run)
      when ReviewSegmentRun
        ReviewSegments::ReconcileRun.call(run.review_run)
      when JudgeSegmentRun
        JudgeSegments::ReconcileRun.call(run.judge_run)
      when FinalizationSegmentRun
        FinalizationSegments::ReconcileRun.call(run.finalization_run)
      else
        raise ArgumentError, "Unsupported AI run type: #{run.class.name}"
      end
    end
  end
end
