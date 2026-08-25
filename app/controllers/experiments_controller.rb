class ExperimentsController < ApplicationController
  def show
    @experiment = Experiment.includes(
      document: :project,
      translation_runs: :llm_model,
      review_round: { review_runs: :reviewer_llm_model }
    ).find(params[:id])
    @reviewer_models = LlmModel.active_openrouter.order(:display_name, :id)
  end
end
