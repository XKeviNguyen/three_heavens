class JudgeRoundsController < ApplicationController
  before_action :require_managed_ai_access, only: %i[create retry_failed]
  def create
    review_round = current_user.review_rounds.find(params[:review_round_id])
    judge_round = Judging::Start.call(
      review_round: review_round,
      judge_ids: judge_round_params[:judge_ids]
    )

    redirect_to judge_round, notice: t("flash_ui.judge.started")
  rescue Judging::Start::Error => error
    @review_round = review_round
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
  end

  def retry_failed
    judge_round = current_user.judge_rounds.find(params[:id])
    result = Judging::RetryFailed.call(judge_round)
    redirect_to judge_round, notice: localized_retry_notice(result, kind: :judge)
  rescue Ai::RetryFailedRuns::Error => error
    redirect_to judge_round, alert: error.message
  end

  private

  def judge_round_params
    params.fetch(:judge_round, ActionController::Parameters.new).permit(
      judge_ids: []
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
    @judge_models = LlmModel.active_openrouter.order(:display_name, :id)
  end
end
