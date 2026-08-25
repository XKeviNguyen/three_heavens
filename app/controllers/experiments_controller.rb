class ExperimentsController < ApplicationController
  def show
    @experiment = Experiment.includes(
      document: :project,
      translation_runs: :llm_model
    ).find(params[:id])
  end
end
