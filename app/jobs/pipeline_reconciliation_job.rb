class PipelineReconciliationJob < ApplicationJob
  queue_as :operations

  def perform(batch_size = Pipelines::Reconcile::DEFAULT_BATCH_SIZE)
    Pipelines::Reconcile.call(batch_size: batch_size)
  end
end
