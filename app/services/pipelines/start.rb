module Pipelines
  class Start
    class Error < StandardError; end
    class InactiveProfileError < Error; end
    class StaleRevisionError < Error; end
    class ConfirmationRequiredError < Error; end
    class ConfigurationUnavailableError < Error; end

    CONFIRMATION_VALUE = "1"

    def self.call(experiment:, user:, workflow_profile_revision:, confirmation:,
                  expected_provider_work_plan_digest: nil, clock: -> { Time.current })
      new(
        experiment: experiment,
        user: user,
        workflow_profile_revision: workflow_profile_revision,
        confirmation: confirmation,
        expected_provider_work_plan_digest: expected_provider_work_plan_digest,
        clock: clock
      ).call
    end

    def initialize(experiment:, user:, workflow_profile_revision:, confirmation:,
                   expected_provider_work_plan_digest:, clock:)
      @experiment = experiment
      @user = user
      @revision = workflow_profile_revision
      @confirmation = confirmation
      @expected_provider_work_plan_digest = expected_provider_work_plan_digest
      @clock = clock
    end

    def call
      raise ConfirmationRequiredError, "Confirm the authorized automatic provider work for this launch" unless confirmation == CONFIRMATION_VALUE

      PipelineRun.transaction do
        profile.lock!
        validate_profile!
        role_models = resolve_all_models!
        execution_plan = LongDocuments::Planner.call(experiment)
        provider_work_plan = LongDocuments::ProviderWorkPlan.call(
          execution_plan: execution_plan,
          role_models: role_models,
          source_character_count: experiment.document.source_text.length
        )
        validate_segmented_authorization!(execution_plan, provider_work_plan)
        now = clock.call
        pipeline_run = experiment.create_pipeline_run!(audit_attributes(role_models, provider_work_plan, now))
        pipeline_run.append_event!(
          event_key: "pipeline_started",
          event_type: "pipeline_started",
          to_stage: "translation",
          metadata: { "authorized_initial_provider_run_count" => pipeline_run.authorized_initial_provider_run_count }
        )
        pipeline_run.append_event!(
          event_key: "translation_started",
          event_type: "translation_started",
          to_stage: "translation"
        )
        TranslationExperiments::Start.call(
          experiment: experiment,
          llm_models: role_models.fetch("translator"),
          capability_snapshots: LongDocuments::ProviderWorkPlan.capability_snapshots(
            provider_work_plan,
            "translator"
          )
        )
        pipeline_run
      end
    rescue WorkflowProfiles::RoutingModels::ConfigurationUnavailableError => error
      raise ConfigurationUnavailableError, error.message
    rescue Ai::ContextBudget::Error, LongDocuments::Planner::SourceChangedError => error
      raise ConfigurationUnavailableError, error.message
    end

    private

    attr_reader :clock, :confirmation, :expected_provider_work_plan_digest, :experiment, :revision, :user

    def profile
      revision.workflow_profile
    end

    def validate_profile!
      raise ActiveRecord::RecordNotSaved, "Experiment must be persisted" unless experiment.persisted?
      owner_id = user&.id
      unless owner_id && experiment.document.project.user_id == owner_id && profile.user_id == owner_id
        raise ActiveRecord::RecordNotFound, "Automatic workflow not found"
      end
      raise InactiveProfileError, "The selected workflow profile is inactive" unless profile.active?
      unless revision.workflow_profile_id == profile.id
        raise ActiveRecord::RecordNotFound, "Workflow profile not found"
      end
      unless profile.current_revision_id == revision.id
        raise StaleRevisionError, "This workflow profile changed. Review its latest revision before launching."
      end
    end

    def resolve_all_models!
      WorkflowProfileModelSelection::ROLES.to_h do |role|
        [ role, WorkflowProfiles::RoutingModels.call(revision: revision, role: role) ]
      end
    end

    def validate_segmented_authorization!(execution_plan, provider_work_plan)
      return unless execution_plan

      expected = LongDocuments::ProviderWorkPlan.digest(provider_work_plan)
      supplied = expected_provider_work_plan_digest.to_s
      return if supplied.length == expected.length &&
                ActiveSupport::SecurityUtils.secure_compare(supplied, expected)

      raise ConfirmationRequiredError,
            "Confirm the exact segmented provider-work plan for this launch"
    end

    def audit_attributes(role_models, provider_work_plan, now)
      counts = role_models.transform_values(&:size)
      {
        workflow_profile_revision: revision,
        status: :running,
        current_stage: :translation,
        completion_mode: revision.completion_mode,
        translator_count: counts.fetch("translator"),
        reviewer_count: counts.fetch("reviewer"),
        judge_count: counts.fetch("judge"),
        finalizer_count: counts.fetch("finalizer"),
        authorized_initial_provider_run_count: provider_work_plan.fetch("authorized_initial_provider_request_slots"),
        provider_work_plan: provider_work_plan,
        configuration_digest: revision.configuration_digest,
        confirmed_at: now,
        started_at: now
      }
    end
  end
end
