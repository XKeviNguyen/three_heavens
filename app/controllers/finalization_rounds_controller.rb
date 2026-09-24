class FinalizationRoundsController < ApplicationController
  before_action :require_managed_ai_access, only: :retry_failed
  def retry_failed
    final_translation = current_user.final_translations.find(params[:final_translation_id])
    round = final_translation.finalization_rounds.find(params[:id])
    result = Finalizations::RetryFailed.call(round)
    redirect_to final_translation, notice: localized_retry_notice(result, kind: :refinement)
  rescue Ai::RetryFailedRuns::Error, FinalTranslations::Error => error
    redirect_to final_translation, alert: error.message
  end
end
