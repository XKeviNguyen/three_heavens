class ReviewRoundsController < ApplicationController
  def create
    experiment = Experiment.find(params[:experiment_id])
    review_round = BlindReviews::Start.call(
      experiment: experiment,
      reviewer_ids: review_round_params[:reviewer_ids]
    )

    redirect_to review_round, notice: "Blind review started."
  rescue BlindReviews::Start::Error => error
    @experiment = experiment
    load_experiment_page
    flash.now[:alert] = error.message
    render "experiments/show", status: :unprocessable_content
  end

  def show
    @review_round = ReviewRound.includes(
      :judge_round,
      experiment: { document: :project },
      review_runs: [
        :reviewer_llm_model,
        { review_evaluations: { translation_run: :llm_model } }
      ]
    ).find(params[:id])
    @judge_models = LlmModel.active_openrouter.order(:display_name, :id)
  end

  private

  def review_round_params
    params.fetch(:review_round, ActionController::Parameters.new).permit(
      reviewer_ids: []
    )
  end

  def load_experiment_page
    @experiment = Experiment.includes(
      document: :project,
      translation_runs: :llm_model,
      review_round: { review_runs: :reviewer_llm_model }
    ).find(@experiment.id)
    @reviewer_models = LlmModel.active_openrouter.order(:display_name, :id)
  end
end
