class FinalizationRoundsController < ApplicationController
  def retry_failed
    final_translation = current_user.final_translations.find(params[:final_translation_id])
    round = final_translation.finalization_rounds.find(params[:id])
    result = Finalizations::RetryFailed.call(round)
    redirect_to final_translation, notice: retry_notice(result)
  rescue Ai::RetryFailedRuns::Error, FinalTranslations::Error => error
    redirect_to final_translation, alert: error.message
  end

  private

  def retry_notice(result)
    return "No failed refinement runs need retrying." if result.retried_count.zero?
    failed_count = result.retried_count - result.enqueued_count
    if result.enqueued_count.zero?
      return "Retry could not be queued. The failed refinement runs remain available for another explicit retry."
    end
    if failed_count.positive?
      return "Queued #{result.enqueued_count} failed refinement run(s); #{failed_count} could not be queued and remain available for retry."
    end

    "Queued #{result.retried_count} failed refinement run(s) for retry."
  end
end
