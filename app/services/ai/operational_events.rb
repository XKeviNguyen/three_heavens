module Ai
  module OperationalEvents
    module_function

    def emit(event, run, active_job_id: nil, **fields)
      experiment = experiment_for(run)
      Operations::EventLogger.emit(
        event,
        active_job_id: active_job_id,
        scheduled_job_id: run.scheduled_job_id,
        execution_attempt: run.execution_attempt,
        run_type: run.class.name.underscore,
        run_id: run.id,
        experiment_id: experiment.id,
        pipeline_run_id: experiment.pipeline_run&.id,
        **fields
      )
    end

    def experiment_for(run)
      case run
      when TranslationRun
        run.experiment
      when ReviewRun
        run.review_round.experiment
      when JudgeRun
        run.judge_round.experiment
      when FinalizationRun
        run.finalization_round.final_translation.judge_round.experiment
      when TranslationSegmentRun
        run.translation_run.experiment
      when ReviewSegmentRun
        run.review_run.review_round.experiment
      when JudgeSegmentRun
        run.judge_run.judge_round.experiment
      when FinalizationSegmentRun
        run.finalization_run.finalization_round.final_translation.experiment
      else
        raise ArgumentError, "unsupported AI run type"
      end
    end
    private_class_method :experiment_for
  end
end
