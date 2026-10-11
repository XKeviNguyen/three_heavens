class FinalizationRoundsController < ApplicationController
  before_action :authorize_retry_payer, only: :retry_failed
  def retry_failed
    final_translation = current_user.final_translations.find(params[:final_translation_id])
    round = final_translation.finalization_rounds.find(params[:id])
    return unless retry_payer_confirmed?(final_translation)

    result = Finalizations::RetryFailed.call(round, billing: @retry_billing)
    redirect_to final_translation, notice: localized_retry_notice(result, kind: :refinement)
  rescue Ai::RetryFailedRuns::Error, FinalTranslations::Error => error
    redirect_to final_translation, alert: error.message
  end
end
