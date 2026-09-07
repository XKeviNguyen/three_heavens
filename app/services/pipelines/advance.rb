module Pipelines
  class Advance
    BLOCKED_MESSAGES = {
      "stage_failed" => "One or more runs failed. Use the existing explicit retry action on the linked stage page.",
      "configuration_unavailable" => "The next stage's authorized model configuration is unavailable. Stop automation and continue manually, or restore the original model configuration.",
      "stage_conflict" => "Existing workflow state conflicts with this automatic stage. Stop automation and continue from the linked stage page.",
      "reference_context_budget" => TranslationReferences::ContextBudgetMessage::MESSAGE
    }.freeze

    def self.call(pipeline_run:)
      new(pipeline_run: pipeline_run).call
    end

    def initialize(pipeline_run:)
      @pipeline_run = pipeline_run
    end

    def call
      pipeline_run.with_lock do
        return pipeline_run if pipeline_run.stopped? || pipeline_run.ready_for_editor?

        send("advance_#{pipeline_run.current_stage}")
      rescue WorkflowProfiles::RoutingModels::ConfigurationUnavailableError
        block!(reason: "configuration_unavailable")
      rescue BlindReviews::Start::Error,
             Judging::Start::Error,
             FinalTranslations::Error => error
        reason = if error.message == TranslationReferences::ContextBudgetMessage::MESSAGE
          "reference_context_budget"
        else
          "stage_conflict"
        end
        block!(reason: reason)
      end
      pipeline_run
    end

    private

    attr_reader :pipeline_run

    def revision
      pipeline_run.workflow_profile_revision
    end

    def experiment
      pipeline_run.experiment
    end

    def advance_translation
      experiment.reload
      return block!(reason: "stage_failed") if experiment.failed?
      return mark_running! unless experiment.completed?

      models = routing_models("reviewer")
      review_round = BlindReviews::Start.call(
        experiment: experiment,
        reviewer_ids: models.map(&:id),
        capability_snapshots: capability_snapshots("reviewer")
      )
      transition!(
        from: "translation",
        to: "review",
        completed_event: "translation_completed",
        started_event: "review_started"
      )
      review_round
    end

    def advance_review
      round = experiment.review_round
      return advance_translation unless round

      round.reload
      return block!(reason: "stage_failed") if round.failed?
      return mark_running! unless round.completed?

      models = routing_models("judge")
      Judging::Start.call(
        review_round: round,
        judge_ids: models.map(&:id),
        capability_snapshots: capability_snapshots("judge")
      )
      transition!(
        from: "review",
        to: "judge",
        completed_event: "review_completed",
        started_event: "judge_started"
      )
    end

    def advance_judge
      round = experiment.review_round&.judge_round
      return advance_review unless round

      round.reload
      return block!(reason: "stage_failed") if round.failed?
      return mark_running! unless round.completed?

      final_translation = FinalTranslations::Create.call(judge_round: round)
      pipeline_run.append_event!(
        event_key: "judge_completed",
        event_type: "judge_completed",
        from_stage: "judge",
        to_stage: "judge"
      )
      pipeline_run.append_event!(
        event_key: "final_workspace_created",
        event_type: "final_workspace_created",
        from_stage: "judge",
        to_stage: revision.winner_draft? ? "editor" : "finalization"
      )

      if revision.winner_draft?
        ready_for_editor!(from: "judge")
      else
        models = routing_models("finalizer")
        finalization_round = Finalizations::Start.call(
          final_translation: final_translation,
          finalizer_ids: models.map(&:id),
          capability_snapshots: capability_snapshots("finalizer")
        )
        pipeline_run.update!(
          status: :running,
          current_stage: :finalization,
          finalization_round: finalization_round,
          blocked_stage: nil,
          blocked_reason_code: nil,
          blocked_message: nil
        )
        pipeline_run.append_event!(
          event_key: "refinement_started",
          event_type: "refinement_started",
          from_stage: "judge",
          to_stage: "finalization"
        )
        emit_pipeline_event("pipeline_stage_advanced", pipeline_stage: "finalization", outcome: "advanced")
      end
    end

    def advance_finalization
      round = pipeline_run.finalization_round
      return advance_judge unless round

      round.reload
      return block!(reason: "stage_failed") if round.failed?
      return mark_running! unless round.completed?

      pipeline_run.append_event!(
        event_key: "refinement_completed",
        event_type: "refinement_completed",
        from_stage: "finalization",
        to_stage: "editor"
      )
      ready_for_editor!(from: "finalization")
    end

    def advance_editor
      ready_for_editor!(from: pipeline_run.current_stage)
    end

    def routing_models(role)
      WorkflowProfiles::RoutingModels.call(revision: revision, role: role)
    end

    def capability_snapshots(role)
      return {} if pipeline_run.provider_work_plan.blank?

      LongDocuments::ProviderWorkPlan.capability_snapshots(pipeline_run.provider_work_plan, role)
    end

    def transition!(from:, to:, completed_event:, started_event:)
      pipeline_run.append_event!(
        event_key: completed_event,
        event_type: completed_event,
        from_stage: from,
        to_stage: to
      )
      pipeline_run.update!(
        status: :running,
        current_stage: to,
        blocked_stage: nil,
        blocked_reason_code: nil,
        blocked_message: nil
      )
      pipeline_run.append_event!(
        event_key: started_event,
        event_type: started_event,
        from_stage: from,
        to_stage: to
      )
      emit_pipeline_event("pipeline_stage_advanced", pipeline_stage: to, outcome: "advanced")
    end

    def block!(reason:)
      stage = pipeline_run.current_stage
      return if pipeline_run.blocked? &&
                pipeline_run.blocked_stage == stage &&
                pipeline_run.blocked_reason_code == reason

      episode = block_episode_events(stage).count + 1
      pipeline_run.update!(
        status: :blocked,
        blocked_stage: stage,
        blocked_reason_code: reason,
        blocked_message: BLOCKED_MESSAGES.fetch(reason)
      )
      pipeline_run.append_event!(
        event_key: "#{stage}_blocked:episode:#{episode}:#{reason}",
        event_type: reason == "configuration_unavailable" ? "configuration_blocked" : "#{stage}_blocked",
        from_stage: stage,
        to_stage: stage,
        reason_code: reason,
        metadata: { "episode" => episode }
      )
      emit_pipeline_event(
        "pipeline_blocked",
        pipeline_stage: stage,
        status: "blocked",
        error_code: reason,
        outcome: "blocked"
      )
    end

    def mark_running!
      return unless pipeline_run.blocked?

      stage = pipeline_run.current_stage
      episode = current_block_episode(stage)
      pipeline_run.update!(
        status: :running,
        blocked_stage: nil,
        blocked_reason_code: nil,
        blocked_message: nil
      )
      pipeline_run.append_event!(
        event_key: "#{stage}_retry_resumed:episode:#{episode}",
        event_type: "#{stage}_retry_resumed",
        from_stage: stage,
        to_stage: stage,
        metadata: { "episode" => episode }
      )
    end

    def block_episode_events(stage)
      pipeline_run.events.where(
        from_stage: stage,
        event_type: [ "#{stage}_blocked", "configuration_blocked" ]
      )
    end

    def current_block_episode(stage)
      latest = block_episode_events(stage).order(:sequence_number).last
      Integer(latest&.metadata&.fetch("episode", nil), exception: false) || [ block_episode_events(stage).count, 1 ].max
    end

    def ready_for_editor!(from:)
      now = Time.current
      pipeline_run.update!(
        status: :ready_for_editor,
        current_stage: :editor,
        blocked_stage: nil,
        blocked_reason_code: nil,
        blocked_message: nil,
        ready_for_editor_at: now
      )
      pipeline_run.append_event!(
        event_key: "ready_for_editor",
        event_type: "ready_for_editor",
        from_stage: from,
        to_stage: "editor"
      )
      emit_pipeline_event(
        "pipeline_ready_for_editor",
        pipeline_stage: "editor",
        status: "ready_for_editor",
        outcome: "success"
      )
    end

    def emit_pipeline_event(event, **fields)
      Operations::EventLogger.emit(
        event,
        pipeline_run_id: pipeline_run.id,
        experiment_id: pipeline_run.experiment_id,
        **fields
      )
    end
  end
end
