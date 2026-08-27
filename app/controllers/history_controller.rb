class HistoryController < ApplicationController
  def index
    @history = History::ExperimentQuery.new(
      experiment_scope: current_user.experiments,
      page: params[:page]
    ).call
  end
end
