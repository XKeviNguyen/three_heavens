class JudgeRoundsController < ApplicationController
  include CatalogModelSelection

  before_action :require_ai_billing_authorization, only: %i[create retry_failed replace_judge]
  def create
    review_round = current_user.review_rounds.find(params[:review_round_id])
    judge_ids = resolved_model_ids(
      identifiers: judge_round_params[:judge_identifiers],
      saved_ids: judge_round_params[:judge_ids],
      role: "judge",
      maximum: Ai::UsageLimits::MAX_JUDGES
    )
    judge_round = Judging::Start.call(review_round: review_round, judge_ids: judge_ids)

    redirect_to judge_round, notice: t("flash_ui.judge.started")
  rescue Judging::Start::Error, CatalogModelSelection::Error => error
    @review_round = review_round
    @selected_judges = LlmModel.where(id: judge_ids).to_a if judge_ids
    load_review_round_page
    flash.now[:alert] = error.message
    render "review_rounds/show", status: :unprocessable_content
  end

  def show
    @judge_round = current_user.judge_rounds.includes(
      :winner_translation_run,
      :final_translation,
      review_round: { experiment: { document: :project } },
      judge_runs: [
        :judge_llm_model,
        :judge_segment_runs,
        { winner_translation_run: :llm_model },
        { judge_evaluations: { translation_run: :llm_model } }
      ]
    ).find(params[:id])
    @replaced_judge_runs = @judge_round.all_judge_runs.where.not(superseded_at: nil)
      .includes(:judge_llm_model, superseded_by: :judge_llm_model).order(:superseded_at)
  end

  def retry_failed
    judge_round = current_user.judge_rounds.find(params[:id])
    result = retry_under_shown_payer(judge_round) { |billing| Judging::RetryFailed.call(judge_round, billing: billing) }
    return unless result

    redirect_to judge_round, notice: localized_retry_notice(result, kind: :judge)
  rescue Ai::RetryFailedRuns::Error => error
    redirect_to judge_round, alert: error.message
  end

  # Swaps one failed judge for another model; only the new model's work is
  # billed, under the payer shown on the page.
  def replace_judge
    judge_round = current_user.judge_rounds.find(params[:id])
    replacement = replacement_model(role: "judge")
    replaced = retry_under_shown_payer(judge_round) do |billing|
      Judging::ReplaceFailed.call(
        judge_round: judge_round, judge_run_id: scalar_param(:judge_run_id), replacement: replacement, billing: billing
      )
    end
    return unless replaced

    redirect_to judge_round, notice: t("flash_ui.judge.replaced", name: replacement.display_name)
  rescue Judging::ReplaceFailed::Error, CatalogModelSelection::Error => error
    redirect_to judge_round, alert: error.message
  end

  private

  def judge_round_params
    params.fetch(:judge_round, ActionController::Parameters.new).permit(
      judge_ids: [], judge_identifiers: []
    )
  end


  def load_review_round_page
    @review_round = current_user.review_rounds.includes(
      :judge_round,
      experiment: { document: :project },
      review_runs: [
        :reviewer_llm_model,
        :review_segment_runs,
        { review_evaluations: { translation_run: :llm_model } }
      ]
    ).find(@review_round.id)
    @replaced_review_runs = @review_round.all_review_runs.where.not(superseded_at: nil)
      .includes(:reviewer_llm_model, superseded_by: :reviewer_llm_model).order(:superseded_at)
  end
end
