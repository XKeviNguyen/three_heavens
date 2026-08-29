module Pipelines
  class Start
    class Error < StandardError; end
    class InactiveProfileError < Error; end
    class StaleRevisionError < Error; end
    class ConfirmationRequiredError < Error; end
    class ConfigurationUnavailableError < Error; end

    CONFIRMATION_VALUE = "1"

    def self.call(experiment:, user:, workflow_profile_revision:, confirmation:, clock: -> { Time.current })
      new(
        experiment: experiment,
        user: user,
        workflow_profile_revision: workflow_profile_revision,
        confirmation: confirmation,
        clock: clock
      ).call
    end

    def initialize(experiment:, user:, workflow_profile_revision:, confirmation:, clock:)
      @experiment = experiment
      @user = user
      @revision = workflow_profile_revision
      @confirmation = confirmation
      @clock = clock
    end

    def call
      raise ConfirmationRequiredError, "Confirm the authorized automatic provider work for this launch" unless confirmation == CONFIRMATION_VALUE

      PipelineRun.transaction do
        profile.lock!
        validate_profile!
        role_models = resolve_all_models!
        now = clock.call
        pipeline_run = experiment.create_pipeline_run!(audit_attributes(role_models, now))
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
          llm_models: role_models.fetch("translator")
        )
        pipeline_run
      end
    rescue WorkflowProfiles::RoutingModels::ConfigurationUnavailableError => error
      raise ConfigurationUnavailableError, error.message
    end

    private

    attr_reader :clock, :confirmation, :experiment, :revision, :user

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

    def audit_attributes(role_models, now)
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
        authorized_initial_provider_run_count: counts.values.sum,
        configuration_digest: revision.configuration_digest,
        confirmed_at: now,
        started_at: now
      }
    end
  end
end
