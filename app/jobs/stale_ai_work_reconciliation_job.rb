class StaleAiWorkReconciliationJob < ApplicationJob
  queue_as :operations

  def perform
    Ai::StaleExecutionReconciler.call
  end
end
