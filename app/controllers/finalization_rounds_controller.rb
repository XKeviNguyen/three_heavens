class FinalizationRoundsController < ApplicationController
  before_action :require_ai_billing_authorization, only: :retry_failed
  def retry_failed
    final_translation = current_user.final_translations.find(params[:final_translation_id])
    round = final_translation.finalization_rounds.find(params[:id])
    result = retry_under_shown_payer(final_translation) { |billing| Finalizations::RetryFailed.call(round, billing: billing) }
    return unless result

    redirect_to final_translation, notice: localized_retry_notice(result, kind: :refinement)
  rescue Ai::RetryFailedRuns::Error, FinalTranslations::Error => error
    redirect_to final_translation, alert: error.message
  end
end
