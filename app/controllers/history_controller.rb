class HistoryController < ApplicationController
  def index
    @history = History::ExperimentQuery.new(page: params[:page]).call
  end
end
