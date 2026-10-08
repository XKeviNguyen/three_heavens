class PipelineRunsController < ApplicationController
  before_action :set_pipeline_run

  def show
    @pipeline_run = current_user.pipeline_runs.includes(
      :events,
      workflow_profile_revision: { model_selections: :llm_model },
      experiment: [
        { methodology_profile_revision: :methodology_profile },
        { experiment_reference_revisions: :translation_reference_revision },
        :review_round,
        :final_translation,
        { document: :project },
        { review_round: :judge_round }
      ]
    ).find(@pipeline_run.id)
    @cost_summary = Pipelines::CostSummary.call(experiment: @pipeline_run.experiment)
    @execution_summary = Pipelines::ExecutionSummary.call(experiment: @pipeline_run.experiment)
  end

  def stop
    reject_unexpected_parameters!
    Pipelines::Stop.call(pipeline_run: @pipeline_run)
    redirect_to @pipeline_run, notice: t("flash_ui.pipeline.stopped")
  end

  private

  def set_pipeline_run
    @pipeline_run = current_user.pipeline_runs.find(params[:id])
  end

  def reject_unexpected_parameters!
    submitted = params[:pipeline_run]
    return if submitted.nil? || (submitted.is_a?(ActionController::Parameters) && submitted.empty?)

    raise ActionController::BadRequest, "Unexpected parameters"
  end
end
