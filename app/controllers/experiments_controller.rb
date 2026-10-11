class ExperimentsController < ApplicationController
  before_action :require_ai_billing_authorization, only: :retry_failed
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
    result = retry_under_shown_payer(experiment) { |billing| TranslationExperiments::RetryFailed.call(experiment, billing: billing) }
    return unless result

    redirect_to experiment, notice: localized_retry_notice(result, kind: :translation)
  rescue Ai::RetryFailedRuns::Error => error
    redirect_to experiment, alert: error.message
  end
end
