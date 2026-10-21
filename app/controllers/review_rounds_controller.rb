class ReviewRoundsController < ApplicationController
  include CatalogModelSelection

  before_action :require_ai_billing_authorization, only: %i[create retry_failed replace_reviewer]
  def create
    experiment = current_user.experiments.find(params[:experiment_id])
    reviewer_ids = resolved_model_ids(
      identifiers: review_round_params[:reviewer_identifiers],
      saved_ids: review_round_params[:reviewer_ids],
      role: "reviewer",
      maximum: Ai::UsageLimits::MAX_REVIEWERS
    )
    review_round = BlindReviews::Start.call(experiment: experiment, reviewer_ids: reviewer_ids)

    redirect_to review_round, notice: t("flash_ui.review.started")
  rescue BlindReviews::Start::Error, CatalogModelSelection::Error => error
    @experiment = experiment
    @selected_reviewers = LlmModel.where(id: reviewer_ids).to_a if reviewer_ids
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
    @replaced_review_runs = @review_round.all_review_runs.where.not(superseded_at: nil)
      .includes(:reviewer_llm_model, superseded_by: :reviewer_llm_model).order(:superseded_at)
  end

  def retry_failed
    review_round = current_user.review_rounds.find(params[:id])
    result = retry_under_shown_payer(review_round) { |billing| BlindReviews::RetryFailed.call(review_round, billing: billing) }
    return unless result

    redirect_to review_round, notice: localized_retry_notice(result, kind: :reviewer)
  rescue Ai::RetryFailedRuns::Error => error
    redirect_to review_round, alert: error.message
  end

  # Swaps one failed reviewer for another model; only the new model's work
  # is billed, under the payer shown on the page.
  def replace_reviewer
    review_round = current_user.review_rounds.find(params[:id])
    replacement = replacement_model(role: "reviewer")
    replaced = retry_under_shown_payer(review_round) do |billing|
      BlindReviews::ReplaceFailed.call(
        review_round: review_round, review_run_id: scalar_param(:review_run_id), replacement: replacement, billing: billing
      )
    end
    return unless replaced

    redirect_to review_round, notice: t("flash_ui.review.replaced", name: replacement.display_name)
  rescue BlindReviews::ReplaceFailed::Error, CatalogModelSelection::Error => error
    redirect_to review_round, alert: error.message
  end

  private

  def review_round_params
    params.fetch(:review_round, ActionController::Parameters.new).permit(
      reviewer_ids: [], reviewer_identifiers: []
    )
  end


  def load_experiment_page
    @experiment = current_user.experiments.includes(
      document: :project,
      translation_runs: [ :llm_model, :translation_segment_runs ],
      review_round: { review_runs: :reviewer_llm_model }
    ).find(@experiment.id)
  end
end
