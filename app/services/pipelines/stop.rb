module Pipelines
  class Stop
    def self.call(pipeline_run:, at: Time.current)
      pipeline_run.with_lock do
        return pipeline_run if pipeline_run.stopped? || pipeline_run.ready_for_editor?

        stage = pipeline_run.current_stage
        pipeline_run.update!(
          status: :stopped,
          stopped_at: at,
          blocked_stage: nil,
          blocked_reason_code: nil,
          blocked_message: nil
        )
        pipeline_run.append_event!(
          event_key: "automation_stopped",
          event_type: "automation_stopped",
          from_stage: stage,
          to_stage: stage
        )
      end
      pipeline_run
    end
  end
end
