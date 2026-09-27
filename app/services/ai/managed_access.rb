module Ai
  class ManagedAccess
    DENIED_MESSAGE = "AI translation access is not enabled for this account.".freeze

    def self.user_for(run)
      case run
      when TranslationSegmentRun then user_for(run.translation_run)
      when ReviewSegmentRun then user_for(run.review_run)
      when JudgeSegmentRun then user_for(run.judge_run)
      when FinalizationSegmentRun then user_for(run.finalization_run)
      when TranslationRun then run.experiment.document.project.user
      when ReviewRun then run.review_round.experiment.document.project.user
      when JudgeRun then run.judge_round.review_round.experiment.document.project.user
      when FinalizationRun then run.finalization_round.final_translation.experiment.document.project.user
      else raise ArgumentError, "Unsupported provider run"
      end
    end

    def self.allowed?(user)
      user.active? && user.email_verified? && user.managed_ai_access?
    end
  end
end
