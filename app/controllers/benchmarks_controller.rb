class BenchmarksController < ApplicationController
  def index
    leaderboard = Benchmarking::ModelLeaderboard.new(sort: params[:sort])
    @model_stats = leaderboard.call
    @sort = leaderboard.sort
  end

  def show
    @model = LlmModel.find(params[:id])
    @stats = Benchmarking::ModelLeaderboard.new.call.find { |stats| stats.model.id == @model.id }
    raise ActiveRecord::RecordNotFound unless @stats

    @history = Benchmarking::ModelHistory.new(model: @model).call
  end
end
