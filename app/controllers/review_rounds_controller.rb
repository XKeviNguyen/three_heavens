class ReviewRoundsController < ApplicationController
  before_action :require_managed_ai_access, only: %i[create retry_failed]
  def create
    experiment = current_user.experiments.find(params[:experiment_id])
    review_round = BlindReviews::Start.call(
      experiment: experiment,
      reviewer_ids: review_round_params[:reviewer_ids]
    )

    redirect_to review_round, notice: t("flash_ui.review.started")
  rescue BlindReviews::Start::Error => error
    @experiment = experiment
    load_experiment_page
    flash.now[:alert] = error.message
    render "experiments/show", status: :unprocessable_content
  end

  def show
    @review_round = current_user.review_rounds.includes(
      :judge_round,
      experiment: { document: :project },
      review_runs: [
        :reviewer_llm_model,
        :review_segment_runs,
        { review_evaluations: { translation_run: :llm_model } }
      ]
    ).find(params[:id])
    @judge_models = LlmModel.active_openrouter.order(:display_name, :id)
  end

  def retry_failed
    review_round = current_user.review_rounds.find(params[:id])
    result = BlindReviews::RetryFailed.call(review_round)
    redirect_to review_round, notice: localized_retry_notice(result, kind: :reviewer)
  rescue Ai::RetryFailedRuns::Error => error
    redirect_to review_round, alert: error.message
  end

  private

  def review_round_params
    params.fetch(:review_round, ActionController::Parameters.new).permit(
      reviewer_ids: []
    )
  end

  def load_experiment_page
    @experiment = current_user.experiments.includes(
      document: :project,
      translation_runs: [ :llm_model, :translation_segment_runs ],
      review_round: { review_runs: :reviewer_llm_model }
    ).find(@experiment.id)
    @reviewer_models = LlmModel.active_openrouter.order(:display_name, :id)
  end
end
