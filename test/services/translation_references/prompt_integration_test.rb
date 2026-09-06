require "test_helper"
require_relative "../../support/final_translation_test_helper"
require_relative "../../support/translation_reference_test_helper"

class TranslationReferences::PromptIntegrationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include FinalTranslationTestHelper
  include TranslationReferenceTestHelper

  test "translation review judge and finalization use exact snapshots without identity metadata" do
    reference = create_translation_reference(
      title: "PRIVATE_REFERENCE_TITLE_MARKER",
      source_language: "Vietnamese",
      target_language: "Japanese",
      source_text: "REFERENCE_SOURCE_MARKER",
      approved_translation: "REFERENCE_APPROVED_MARKER"
    )
    selected = reference.current_revision
    final_translation = create_final_translation_workspace(reference_revision: selected)
    experiment = final_translation.experiment

    TranslationReferences::Revise.call(
      translation_reference: reference,
      expected_version: "1",
      attributes: translation_reference_attributes(
        title: "New title",
        source_language: experiment.document.project.source_language,
        target_language: experiment.document.project.target_language,
        source_text: "NEW_SOURCE_MUST_NOT_APPEAR",
        approved_translation: "NEW_APPROVED_MUST_NOT_APPEAR"
      )
    )
    TranslationReferences::ChangeStatus.deactivate(translation_reference: reference)

    prompts = [
      TranslationSegments::Prompt.build(
        experiment: experiment,
        source_text: experiment.document.source_text
      ),
      BlindReviews::Prompt.build(experiment.review_round.review_runs.first),
      Judging::Prompt.build(experiment.judge_round.judge_runs.first),
      Finalizations::Prompt.build(start_finalization_run(final_translation))
    ]

    prompts.each do |prompt|
      data = prompt_data(prompt)
      assert_equal [ {
        "source_text" => "REFERENCE_SOURCE_MARKER",
        "approved_translation" => "REFERENCE_APPROVED_MARKER"
      } ], data.fetch("reference_examples")
      assert_equal "reference_examples", data.fetch("guidance_preference")
      serialized = JSON.generate(data)
      assert_not_includes serialized, "PRIVATE_REFERENCE_TITLE_MARKER"
      assert_not_includes serialized, "NEW_SOURCE_MUST_NOT_APPEAR"
      assert_not_includes serialized, "NEW_APPROVED_MUST_NOT_APPEAR"
      assert data.keys.none? { |key| key.include?("reference_id") || key.include?("user_id") || key == "configuration_digest" }
      assert_includes prompt.fetch(:system_prompt), "Product/system rules"
      assert_includes prompt.fetch(:system_prompt), TranslationGuidance::Policy.precedence_statement("reference_examples")
    end
  end

  test "each guidance preference yields its exact documented semantic precedence" do
    expected = {
      "reference_examples" => "Product/system rules > Reference examples > Experiment instruction > Glossary > Methodology",
      "glossary" => "Product/system rules > Glossary > Experiment instruction > Reference examples > Methodology",
      "experiment_instruction" => "Product/system rules > Experiment instruction > Glossary > Reference examples > Methodology"
    }

    expected.each do |preference, order|
      project = users(:normal).projects.create!(
        name: "#{preference} project",
        source_language: "Vietnamese",
        target_language: "Japanese"
      )
      experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(
        instruction_prompt: "Translate.",
        guidance_preference: preference
      )
      prompt = TranslationSegments::Prompt.build(experiment: experiment, source_text: "Source")

      assert_includes TranslationGuidance::Policy.precedence_statement(preference), order
      assert_includes prompt.fetch(:system_prompt), order
    end
  end

  test "reference examples naturally fail the actual serialized context budget before scheduling" do
    project = users(:normal).projects.create!(
      name: "Reference context",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    experiment = project.documents.create!(title: "Source", source_text: "Short source").experiments.create!(
      instruction_prompt: "Translate."
    )
    model = llm_models(:openrouter_claude)
    model.update!(context_window_tokens: 10_000, max_output_tokens: 4_096)
    baseline = TranslationSegments::Prompt.build(experiment: experiment, source_text: "Short source")
    assert Ai::ContextBudget.call(
      model: model,
      **baseline,
      stage: :translation,
      source_character_count: 12
    )

    reference = create_translation_reference(
      source_text: "S" * 3_000,
      approved_translation: "T" * 3_000
    )
    snapshot_reference(experiment: experiment, revision: reference.current_revision)

    assert_no_enqueued_jobs do
      error = assert_raises TranslationExperiments::Start::ContextBudgetError do
        TranslationExperiments::Start.call(experiment: experiment, llm_models: [ model ])
      end
      assert_equal TranslationReferences::ContextBudgetMessage::MESSAGE, error.message
    end
    assert_empty experiment.reload.translation_runs
  end

  test "a context budget that fails without references keeps its generic message" do
    project = users(:normal).projects.create!(
      name: "Generic context",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    experiment = project.documents.create!(title: "Source", source_text: "S" * 8_000).experiments.create!(
      instruction_prompt: "Translate."
    )
    reference = create_translation_reference
    snapshot_reference(experiment: experiment, revision: reference.current_revision)
    model = llm_models(:openrouter_claude)
    model.update!(context_window_tokens: 6_000, max_output_tokens: 4_096)

    error = assert_raises TranslationExperiments::Start::ContextBudgetError do
      TranslationExperiments::Start.call(experiment: experiment, llm_models: [ model ])
    end
    assert_equal "The selected model cannot safely fit the planned translation request", error.message
  end

  private

  def start_finalization_run(final_translation)
    Finalizations::Start.call(
      final_translation: final_translation,
      finalizer_ids: [ create_finalizer.id ]
    ).finalization_runs.first.tap { clear_enqueued_jobs }
  end

  def prompt_data(prompt)
    user_prompt = prompt.fetch(:user_prompt)
    if user_prompt.start_with?("<UNTRUSTED_")
      JSON.parse(user_prompt.lines[1...-1].join)
    else
      JSON.parse(user_prompt)
    end
  end
end
