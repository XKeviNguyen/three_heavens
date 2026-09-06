class ExperimentsController < ApplicationController
  def show
    @experiment = current_user.experiments.includes(
      methodology_profile_revision: :methodology_profile,
      experiment_reference_revisions: { translation_reference_revision: :translation_reference },
      document: :project,
      translation_runs: [ :llm_model, :translation_segment_runs ],
      pipeline_run: :workflow_profile_revision,
      review_round: { review_runs: :reviewer_llm_model }
    ).find(params[:id])
    @reviewer_models = LlmModel.active_openrouter.order(:display_name, :id)
  end

  def retry_failed
    experiment = current_user.experiments.find(params[:id])
    result = TranslationExperiments::RetryFailed.call(experiment)
    redirect_to experiment, notice: retry_notice(result, "translation")
  rescue Ai::RetryFailedRuns::Error => error
    redirect_to experiment, alert: error.message
  end

  private

  def retry_notice(result, noun)
    return "No failed #{noun} runs need retrying." if result.retried_count.zero?
    failed_count = result.retried_count - result.enqueued_count
    if result.enqueued_count.zero?
      return "Retry could not be queued. The failed #{noun} runs remain available for another explicit retry."
    end
    if failed_count.positive?
      return "Queued #{result.enqueued_count} failed #{noun} run(s); #{failed_count} could not be queued and remain available for retry."
    end

    "Queued #{result.retried_count} failed #{noun} run(s) for retry."
  end
end
