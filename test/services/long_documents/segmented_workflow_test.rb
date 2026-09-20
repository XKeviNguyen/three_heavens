require "test_helper"
require_relative "../../support/authorized_ai_job_helper"
require_relative "../../support/workflow_profile_test_helper"
require_relative "../../support/methodology_profile_test_helper"
require_relative "../../support/translation_reference_test_helper"

class LongDocuments::SegmentedWorkflowTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AuthorizedAiJobHelper
  include WorkflowProfileTestHelper
  include MethodologyProfileTestHelper
  include TranslationReferenceTestHelper

  class FakeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def chat_completion(model_identifier:, instruction_prompt:, source_text:, max_tokens:)
      calls << [ :translation, model_identifier, max_tokens, instruction_prompt.bytesize + source_text.bytesize ]
      result(JSON.parse(source_text).fetch("source_text"))
    end

    def review_completion(model_identifier:, response_schema:, max_tokens:, **)
      calls << [ :review, model_identifier, max_tokens ]
      score = 2 + (calls.count { |call| call.first == :review } % 8)
      labels = response_schema.dig(:properties, :evaluations, :items, :properties, "candidate_label", :enum)
      evaluations = labels.map do |label|
        {
          candidate_label: label,
          faithfulness_score: score,
          naturalness_score: score,
          terminology_score: 9,
          instruction_adherence_score: 9,
          overall_score: score,
          strengths: "Faithful",
          issues: "Minor style issue",
          recommended_corrections: "Polish style",
          suggested_translation: nil
        }
      end
      result(JSON.generate(evaluations: evaluations))
    end

    def judge_completion(model_identifier:, response_schema:, max_tokens:, **)
      calls << [ :judge, model_identifier, max_tokens ]
      labels = response_schema.dig(:properties, :rankings, :items, :properties, :candidate_label, :enum)
      rankings = labels.each_with_index.map do |label, index|
        {
          candidate_label: label,
          rank: index + 1,
          overall_score: 90 - index,
          rationale: "Segment rank #{index + 1}",
          strengths: "Accurate",
          risks: "Minor"
        }
      end
      result(JSON.generate(
        rankings: rankings,
        winner_label: labels.first,
        winner_rationale: "Best segment translation",
        confidence_score: 90
      ))
    end

    def finalization_completion(model_identifier:, max_tokens:, **)
      calls << [ :finalization, model_identifier, max_tokens ]
      result(JSON.generate(
        proposed_translation: "Refined segment.\n",
        change_summary: [ "Polished" ],
        terminology_notes: [],
        warnings: []
      ))
    end

    private

    def result(content)
      Ai::OpenRouterClient::Result.new(
        content: content,
        provider_response_id: "response",
        resolved_model_identifier: "resolved/model",
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15,
        cached_tokens: 0,
        reasoning_tokens: 0,
        cost: BigDecimal("0.001")
      )
    end
  end

  class OneFailureClient < FakeClient
    def initialize
      super
      @fail_next_translation = true
    end

    def chat_completion(**arguments)
      if @fail_next_translation
        @fail_next_translation = false
        raise Ai::OpenRouterClient::PermanentError.new(
          "Injected segment failure",
          code: "invalid_request"
        )
      end

      super
    end
  end

  class WhitespaceStrippingClient < FakeClient
    def chat_completion(model_identifier:, instruction_prompt:, source_text:, max_tokens:)
      calls << [ :translation, model_identifier, max_tokens, instruction_prompt.bytesize + source_text.bytesize ]
      result(JSON.parse(source_text).fetch("source_text").rstrip)
    end

    def finalization_completion(model_identifier:, max_tokens:, **)
      calls << [ :finalization, model_identifier, max_tokens ]
      result(JSON.generate(
        proposed_translation: "Refined segment.",
        change_summary: [ "Polished" ],
        terminology_notes: [],
        warnings: []
      ))
    end
  end

  setup do
    @client = FakeClient.new
    @job_classes = [
      TranslationRunJob, ReviewRunJob, JudgeRunJob, FinalizationRunJob,
      TranslationSegmentRunJob, ReviewSegmentRunJob,
      JudgeSegmentRunJob, FinalizationSegmentRunJob
    ]
    @original_factories = @job_classes.to_h { |job_class| [ job_class, job_class.client_factory ] }
    @job_classes.each { |job_class| job_class.client_factory = -> { @client } }

    project = users(:normal).projects.create!(
      name: "Long document",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    source = Array.new(24) { |index| "Đoạn #{index}: " + ("thần học。" * 55) + "\n\n" }.join
    document = project.documents.create!(title: "Long source", source_text: source)
    @methodology = create_methodology_profile(
      source_language: "Vietnamese",
      target_language: "Japanese",
      guidance: "Use the same complete methodology for every segment."
    )
    @experiment = document.experiments.create!(
      instruction_prompt: "Preserve theological terminology.",
      methodology_profile_revision: @methodology.current_revision
    )
    @reference = create_translation_reference(
      source_language: "Vietnamese",
      target_language: "Japanese",
      source_text: "Complete reference source",
      approved_translation: "完全な参照訳"
    )
    @reference_revision = @reference.current_revision
    snapshot_reference(experiment: @experiment, revision: @reference_revision)
    @models = [ llm_models(:openrouter_claude), llm_models(:openrouter_gpt) ]
    @models.each { |model| model.update!(context_window_tokens: 64_000, max_output_tokens: 4_096) }
  end

  teardown do
    @original_factories.each { |job_class, factory| job_class.client_factory = factory }
  end

  test "complete segmented workflow preserves logical runs blindness aggregation and editorial checkpoint" do
    perform_enqueued_jobs(only: TranslationSegmentRunJob) do
      TranslationExperiments::Start.call(experiment: @experiment, llm_models: @models)
    end

    plan = @experiment.reload.document_execution_plan
    assert_operator plan.segment_count, :>, 1
    assert_equal @experiment.document.source_text, plan.reconstruct_source
    assert_equal @models.size * plan.segment_count, TranslationSegmentRun.count
    assert @experiment.completed?
    assert @experiment.translation_runs.all?(&:completed?)
    assert @experiment.translation_runs.all? { |run| run.translated_text == @experiment.document.source_text }
    assert @experiment.translation_runs.all? { |run| run.cost == BigDecimal("0.001") * plan.segment_count }
    assert_all_segment_prompts_use_methodology(
      plan.segments,
      ->(segment) { TranslationSegments::Prompt.build(experiment: @experiment, source_text: segment.source_text) },
      bounded: false
    )

    TranslationReferences::Revise.call(
      translation_reference: @reference,
      expected_version: "1",
      attributes: translation_reference_attributes(
        source_language: "Vietnamese",
        target_language: "Japanese",
        source_text: "New reference source",
        approved_translation: "新しい参照訳"
      )
    )
    TranslationReferences::ChangeStatus.deactivate(translation_reference: @reference)

    reviewer = @models.first
    perform_enqueued_jobs(only: ReviewSegmentRunJob) do
      @review_round = BlindReviews::Start.call(experiment: @experiment, reviewer_ids: [ reviewer.id ])
    end
    assert @review_round.reload.completed?
    review_run = @review_round.review_runs.first
    assert_all_segment_prompts_use_methodology(
      plan.segments,
      ->(segment) { BlindReviews::Prompt.build(review_run, experiment_segment: segment) }
    )
    labels_by_segment = review_run.review_segment_runs.map do |segment_run|
      segment_run.evaluations.map { |item| item.fetch("candidate_label") }
    end
    assert_equal 1, labels_by_segment.uniq.size
    assert review_run.review_evaluations.all?(&:complete?)
    expected_review_score = review_run.review_segment_runs.sum do |segment_run|
      evaluation = segment_run.evaluations.first
      evaluation.fetch("overall_score") * segment_run.experiment_segment.source_character_count
    end.fdiv(plan.segments.sum(:source_character_count)).round
    assert_equal expected_review_score, review_run.review_evaluations.first.overall_score

    perform_enqueued_jobs(only: JudgeSegmentRunJob) do
      @judge_round = Judging::Start.call(review_round: @review_round, judge_ids: [ @models.last.id ])
    end
    assert @judge_round.reload.completed?
    assert_all_segment_prompts_use_methodology(
      plan.segments,
      ->(segment) { Judging::Prompt.build(@judge_round.judge_runs.first, experiment_segment: segment) }
    )
    expected_winner_id = @judge_round.judge_runs.first.judge_evaluations.order(:anonymous_label).first.translation_run_id
    assert_equal expected_winner_id, @judge_round.winner_translation_run_id

    final_translation = FinalTranslations::Create.call(judge_round: @judge_round)
    assert_equal plan.segment_count, final_translation.current_version.segments.count
    original_content = final_translation.current_version.content

    perform_enqueued_jobs(only: FinalizationSegmentRunJob) do
      @finalization_round = Finalizations::Start.call(
        final_translation: final_translation,
        finalizer_ids: [ @models.first.id ]
      )
    end
    proposal = @finalization_round.reload.finalization_runs.first
    assert proposal.completed?
    assert_all_segment_prompts_use_methodology(
      plan.segments,
      ->(segment) { Finalizations::Prompt.build(proposal, experiment_segment: segment) }
    )
    assert_equal original_content, final_translation.reload.current_version.content
    assert_equal plan.segment_count, proposal.finalization_segment_runs.count

    applied = Finalizations::ApplyProposal.call(
      final_translation: final_translation,
      finalization_run_id: proposal.id
    )
    assert applied.segment_alignment_valid?
    assert_equal plan.segment_count, applied.segments.count
    assert @client.calls.all? { |call| call[2].positive? }

    summary = Pipelines::CostSummary.call(experiment: @experiment)
    logical_run_count = @models.size + 3
    assert_equal logical_run_count, summary.record_count
    assert_equal logical_run_count, summary.known_count
    assert_equal BigDecimal("0.001") * @client.calls.size, summary.known_cost
  end

  test "retry schedules only failed physical work and preserves completed segment lineage" do
    flaky_client = OneFailureClient.new
    TranslationSegmentRunJob.client_factory = -> { flaky_client }

    perform_enqueued_jobs(only: TranslationSegmentRunJob) do
      TranslationExperiments::Start.call(experiment: @experiment, llm_models: @models)
    end

    failed_run = @experiment.reload.translation_runs.failed.sole
    failed_child = failed_run.translation_segment_runs.failed.sole
    completed_children = failed_run.translation_segment_runs.completed.to_a
    original_completed_attempts = completed_children.to_h { |child| [ child.id, child.execution_attempt ] }
    original_scheduled_job_id = failed_child.scheduled_job_id

    result = nil
    assert_enqueued_jobs 1, only: TranslationSegmentRunJob do
      result = TranslationExperiments::RetryFailed.call(@experiment)
    end
    assert_equal 1, result.retried_count
    assert_equal 1, result.enqueued_count
    assert failed_child.reload.pending?
    assert_not_equal original_scheduled_job_id, failed_child.scheduled_job_id
    assert_nil failed_run.reload.cost
    assert_not failed_run.telemetry_complete?

    perform_enqueued_jobs(only: TranslationSegmentRunJob)

    assert @experiment.reload.completed?
    assert failed_run.reload.telemetry_complete?
    assert_equal 2, failed_child.reload.execution_attempt
    completed_children.each do |child|
      assert_equal original_completed_attempts.fetch(child.id), child.reload.execution_attempt
    end
  end

  test "application restores source join boundaries stripped by translation and finalization providers" do
    @client = WhitespaceStrippingClient.new

    perform_enqueued_jobs(only: TranslationSegmentRunJob) do
      TranslationExperiments::Start.call(experiment: @experiment, llm_models: @models)
    end
    plan = @experiment.reload.document_execution_plan
    expected_translation = LongDocuments::SegmentReassembler.call(
      plan.segments.map { |segment| [ segment, segment.source_text.rstrip ] }
    )
    assert @experiment.translation_runs.all? { |run| run.translated_text == expected_translation }
    assert_includes expected_translation, "\n\n"

    perform_enqueued_jobs(only: ReviewSegmentRunJob) do
      @review_round = BlindReviews::Start.call(
        experiment: @experiment,
        reviewer_ids: [ @models.first.id ]
      )
    end
    perform_enqueued_jobs(only: JudgeSegmentRunJob) do
      @judge_round = Judging::Start.call(
        review_round: @review_round,
        judge_ids: [ @models.last.id ]
      )
    end
    final_translation = FinalTranslations::Create.call(judge_round: @judge_round)
    perform_enqueued_jobs(only: FinalizationSegmentRunJob) do
      @finalization_round = Finalizations::Start.call(
        final_translation: final_translation,
        finalizer_ids: [ @models.first.id ]
      )
    end

    expected_proposal = LongDocuments::SegmentReassembler.call(
      plan.segments.map { |segment| [ segment, "Refined segment." ] }
    )
    proposal = @finalization_round.reload.finalization_runs.sole
    assert_equal expected_proposal, proposal.proposed_translation
    assert_includes expected_proposal, "\n\n"

    applied = Finalizations::ApplyProposal.call(
      final_translation: final_translation,
      finalization_run_id: proposal.id
    )
    assert_equal expected_proposal, applied.content
  end

  test "partial physical costs produce one known incomplete logical total" do
    plan = LongDocuments::Planner.call(@experiment)
    run = @experiment.translation_runs.create!(
      llm_model: @models.first,
      status: :running,
      started_at: Time.current
    )
    known_costs = [ BigDecimal("0.01"), BigDecimal("0.02") ]
    plan.segments.each_with_index do |segment, index|
      run.translation_segment_runs.create!(
        experiment_segment: segment,
        status: :completed,
        translated_text: segment.source_text.rstrip,
        prompt_tokens: 10,
        completion_tokens: 5,
        total_tokens: 15,
        cached_tokens: 0,
        reasoning_tokens: 0,
        cost: known_costs[index],
        completed_at: Time.current,
        context_window_tokens_snapshot: 64_000,
        max_output_tokens_snapshot: 4_096,
        estimated_input_tokens: 1_000,
        reserved_output_tokens: 4_096,
        context_safety_margin_tokens: 1_024,
        budget_policy_version: Ai::ContextBudget::POLICY_VERSION
      )
    end

    TranslationSegments::ReconcileRun.call(run)

    assert_equal BigDecimal("0.03"), run.reload.cost
    assert_not run.cost_complete?
    assert run.telemetry_complete?

    summary = Pipelines::CostSummary.call(experiment: @experiment)
    assert_equal BigDecimal("0.03"), summary.known_cost
    assert_equal 1, summary.known_count
    assert_equal 0, summary.complete_count
    assert_equal 1, summary.record_count
    assert summary.incomplete?

    entry = History::ExperimentQuery.new(experiment_scope: Experiment.where(id: @experiment.id)).call.entries.sole
    assert_equal BigDecimal("0.03"), entry.known_system_cost
    assert_equal 1, entry.cost_sample_count
    assert_equal 0, entry.cost_complete_count
    assert entry.cost_telemetry_incomplete?
  end

  test "stale physical work reconciles its logical parent and remains explicitly retryable" do
    TranslationExperiments::Start.call(experiment: @experiment, llm_models: @models)
    target = @experiment.translation_runs.first.translation_segment_runs.first
    target.update_column(:pending_since, Ai::StaleExecutionPolicy.cutoff(now: Time.current) - 1.second)

    result = Ai::StaleExecutionReconciler.call(batch_size: 1)

    assert_equal 1, result.failed_counts.fetch("TranslationSegmentRun")
    assert target.reload.failed?
    perform_enqueued_jobs(only: TranslationSegmentRunJob)
    assert target.translation_run.reload.failed?
    assert @experiment.reload.failed?

    assert_enqueued_jobs 1, only: TranslationSegmentRunJob do
      TranslationExperiments::RetryFailed.call(@experiment)
    end
    perform_enqueued_jobs(only: TranslationSegmentRunJob)

    assert target.reload.completed?
    assert target.translation_run.reload.completed?
    assert @experiment.reload.completed?
  end

  test "manual edit invalidates segmented refinement alignment" do
    perform_enqueued_jobs(only: TranslationSegmentRunJob) do
      TranslationExperiments::Start.call(experiment: @experiment, llm_models: @models)
    end
    perform_enqueued_jobs(only: ReviewSegmentRunJob) do
      @review_round = BlindReviews::Start.call(experiment: @experiment, reviewer_ids: [ @models.first.id ])
    end
    perform_enqueued_jobs(only: JudgeSegmentRunJob) do
      @judge_round = Judging::Start.call(review_round: @review_round, judge_ids: [ @models.last.id ])
    end
    final_translation = FinalTranslations::Create.call(judge_round: @judge_round)
    edited = FinalTranslations::SaveRevision.call(
      final_translation: final_translation,
      content: final_translation.current_version.content + "\nEditor note",
      expected_version_number: 1
    )

    assert_not edited.segment_alignment_valid?
    assert_raises(FinalTranslations::InvalidStateError) do
      Finalizations::Start.call(final_translation: final_translation, finalizer_ids: [ @models.first.id ])
    end
    assert_equal 0, final_translation.finalization_rounds.count

    returned_to_seed_text = FinalTranslations::SaveRevision.call(
      final_translation: final_translation,
      content: final_translation.versions.find_by!(version_number: 1).content,
      expected_version_number: edited.version_number
    )
    assert_not returned_to_seed_text.segment_alignment_valid?
    restored = FinalTranslations::RestoreRevision.call(
      final_translation: final_translation,
      version_id: final_translation.versions.find_by!(version_number: 1).id,
      expected_version_number: returned_to_seed_text.version_number
    )
    assert restored.segment_alignment_valid?
    assert_equal final_translation.experiment.document_execution_plan.segment_count, restored.segments.count
  end

  test "automatic pipeline preserves initial capabilities through every segmented stage" do
    selected_methodology = @methodology.current_revision
    profile = create_workflow_profile(completion_mode: "refinement_proposals")
    revision = profile.current_revision
    role_models = WorkflowProfileModelSelection::ROLES.to_h do |role|
      [ role, revision.selections_for(role).map(&:llm_model) ]
    end
    preview = LongDocuments::ProviderWorkPlan.call(
      execution_plan: LongDocuments::ProviderWorkPlan::Preview.new(
        segment_count: LongDocuments::Segmenter.call(@experiment.document.source_text).size
      ),
      role_models: role_models,
      source_character_count: @experiment.document.source_text.length
    )

    perform_enqueued_jobs(only: TranslationSegmentRunJob) do
      @pipeline = Pipelines::Start.call(
        experiment: @experiment,
        user: users(:normal),
        workflow_profile_revision: revision,
        confirmation: "1",
        expected_provider_work_plan_digest: LongDocuments::ProviderWorkPlan.digest(preview)
      )
    end
    clear_enqueued_jobs
    MethodologyProfiles::Revise.call(
      methodology_profile: @methodology,
      expected_version: "1",
      attributes: methodology_profile_attributes(
        source_language: "Vietnamese",
        target_language: "Japanese",
        guidance: "A later methodology revision must not affect the running pipeline."
      )
    )
    MethodologyProfiles::ChangeStatus.deactivate(methodology_profile: @methodology)
    role_models.values.flatten.uniq.each do |model|
      model.update!(context_window_tokens: 8_000, max_output_tokens: 512)
    end

    perform_enqueued_jobs(only: ReviewSegmentRunJob) { Pipelines::Advance.call(pipeline_run: @pipeline) }
    clear_enqueued_jobs
    perform_enqueued_jobs(only: JudgeSegmentRunJob) { Pipelines::Advance.call(pipeline_run: @pipeline) }
    clear_enqueued_jobs
    perform_enqueued_jobs(only: FinalizationSegmentRunJob) { Pipelines::Advance.call(pipeline_run: @pipeline) }
    clear_enqueued_jobs
    Pipelines::Advance.call(pipeline_run: @pipeline)

    assert @pipeline.reload.ready_for_editor?
    assert @pipeline.current_stage_editor?
    assert @pipeline.experiment.final_translation.draft?
    assert_equal 1, @pipeline.experiment.final_translation.versions.count
    assert_equal selected_methodology, @pipeline.experiment.reload.methodology_profile_revision
    plan = @pipeline.experiment.document_execution_plan
    review_run = @pipeline.experiment.review_round.review_runs.sole
    judge_run = @pipeline.experiment.review_round.judge_round.judge_runs.sole
    finalization_run = @pipeline.finalization_round.finalization_runs.sole
    [
      ->(segment) { TranslationSegments::Prompt.build(experiment: @pipeline.experiment, source_text: segment.source_text) },
      ->(segment) { BlindReviews::Prompt.build(review_run, experiment_segment: segment) },
      ->(segment) { Judging::Prompt.build(judge_run, experiment_segment: segment) },
      ->(segment) { Finalizations::Prompt.build(finalization_run, experiment_segment: segment) }
    ].each_with_index do |builder, index|
      assert_all_segment_prompts_use_guidance(
        plan.segments,
        builder,
        guidance: selected_methodology.guidance,
        bounded: index.positive?
      )
    end
    segment_runs = @pipeline.experiment.review_round.review_runs.flat_map(&:review_segment_runs) +
      @pipeline.experiment.review_round.judge_round.judge_runs.flat_map(&:judge_segment_runs) +
      @pipeline.finalization_round.finalization_runs.flat_map(&:finalization_segment_runs)
    assert segment_runs.all? { |run| run.context_window_tokens_snapshot == 64_000 }
    assert segment_runs.all? { |run| run.max_output_tokens_snapshot == 4_096 }
  end

  test "historical long workflows without segment lineage retain whole-document execution" do
    @models.each { |model| model.update!(context_window_tokens: 256_000, max_output_tokens: 4_096) }
    @models.each do |model|
      @experiment.translation_runs.create!(
        llm_model: model,
        status: :completed,
        translated_text: @experiment.document.source_text,
        completed_at: Time.current
      )
    end
    @experiment.update!(status: :completed)

    perform_enqueued_jobs(only: ReviewRunJob) do
      @review_round = BlindReviews::Start.call(
        experiment: @experiment,
        reviewer_ids: [ @models.first.id ]
      )
    end
    perform_enqueued_jobs(only: JudgeRunJob) do
      @judge_round = Judging::Start.call(
        review_round: @review_round,
        judge_ids: [ @models.last.id ]
      )
    end
    final_translation = FinalTranslations::Create.call(judge_round: @judge_round)
    perform_enqueued_jobs(only: FinalizationRunJob) do
      @finalization_round = Finalizations::Start.call(
        final_translation: final_translation,
        finalizer_ids: [ @models.first.id ]
      )
    end

    assert_nil @experiment.reload.document_execution_plan
    assert @review_round.review_runs.sole.completed?
    assert_not @review_round.review_runs.sole.segmented?
    assert @judge_round.judge_runs.sole.completed?
    assert_not @judge_round.judge_runs.sole.segmented?
    assert @finalization_round.finalization_runs.sole.completed?
    assert_not @finalization_round.finalization_runs.sole.segmented?
  end

  private

  def assert_all_segment_prompts_use_methodology(segments, builder, bounded: true)
    assert_all_segment_prompts_use_guidance(
      segments,
      builder,
      guidance: @methodology.current_revision.guidance,
      bounded: bounded
    )
  end

  def assert_all_segment_prompts_use_guidance(segments, builder, guidance:, bounded:)
    segments.each do |segment|
      prompt = builder.call(segment)
      data = if bounded
        boundary = prompt.fetch(:user_prompt).match(/\A<([^>]+)>\n/)[1]
        JSON.parse(prompt.fetch(:user_prompt).delete_prefix("<#{boundary}>\n").delete_suffix("</#{boundary}>\n"))
      else
        JSON.parse(prompt.fetch(:user_prompt))
      end
      assert_equal guidance, data.fetch("translation_methodology")
      assert_equal [ {
        "source_text" => @reference_revision.source_text,
        "approved_translation" => @reference_revision.approved_translation
      } ], data.fetch("reference_examples")
      assert_equal "reference_examples", data.fetch("guidance_preference")
    end
  end
end
