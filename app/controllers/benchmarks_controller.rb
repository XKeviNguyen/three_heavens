class BenchmarksController < ApplicationController
  def index
    leaderboard = Benchmarking::ModelLeaderboard.new(
      experiment_scope: benchmark_experiment_scope,
      sort: params[:sort]
    )
    @model_stats = leaderboard.call
    @sort = leaderboard.sort
  end

  def show
    @model = LlmModel.find(params[:id])
    @stats = Benchmarking::ModelLeaderboard.new(
      experiment_scope: benchmark_experiment_scope
    ).call.find { |stats| stats.model.id == @model.id }
    raise ActiveRecord::RecordNotFound unless @stats

    @history = Benchmarking::ModelHistory.new(
      model: @model,
      experiment_scope: benchmark_experiment_scope
    ).call
  end

  private

  def benchmark_experiment_scope
    @benchmark_experiment_scope ||= current_user.admin? ? Experiment.all : current_user.experiments
  end
end
