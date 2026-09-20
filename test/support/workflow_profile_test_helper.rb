module WorkflowProfileTestHelper
  def workflow_profile_attributes(completion_mode: "winner_draft", name: "Faithful automatic workflow", finalizer_ids: nil)
    first = llm_models(:openrouter_claude)
    second = llm_models(:openrouter_gpt)
    {
      name: name,
      description: "Deterministic test configuration",
      completion_mode: completion_mode,
      translator_ids: [ first.id, second.id ],
      reviewer_ids: [ first.id ],
      judge_ids: [ second.id ],
      finalizer_ids: finalizer_ids || (completion_mode == "refinement_proposals" ? [ first.id ] : [])
    }
  end

  def create_workflow_profile(user: users(:normal), **options)
    WorkflowProfiles::Create.call(
      user: user,
      attributes: workflow_profile_attributes(**options)
    )
  end

  def create_pipeline_run(experiment:, profile: create_workflow_profile)
    revision = profile.current_revision
    counts = WorkflowProfileModelSelection::ROLES.to_h { |role| [ role, revision.role_count(role) ] }
    experiment.create_pipeline_run!(
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
      confirmed_at: Time.current,
      started_at: Time.current
    ).tap do |pipeline|
      pipeline.append_event!(event_key: "pipeline_started", event_type: "pipeline_started", to_stage: "translation")
      pipeline.append_event!(event_key: "translation_started", event_type: "translation_started", to_stage: "translation")
    end
  end
end
