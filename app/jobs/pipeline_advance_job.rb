class PipelineAdvanceJob < ApplicationJob
  queue_as :operations

  discard_on ActiveRecord::RecordNotFound

  def perform(pipeline_run_id)
    Pipelines::Advance.call(pipeline_run: PipelineRun.find(pipeline_run_id))
  end
end
