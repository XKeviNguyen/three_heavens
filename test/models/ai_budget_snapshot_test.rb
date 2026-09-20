require "test_helper"

class Ai::BudgetSnapshotTest < ActiveSupport::TestCase
  setup do
    project = users(:normal).projects.create!(
      name: "Budget snapshot",
      source_language: "Vietnamese",
      target_language: "Japanese"
    )
    experiment = project.documents.create!(title: "Source", source_text: "Source").experiments.create!(
      instruction_prompt: "Translate."
    )
    @run = experiment.translation_runs.create!(llm_model: llm_models(:openrouter_claude))
  end

  test "historical absent snapshots remain valid while partial or unsafe snapshots fail" do
    assert @run.valid?

    @run.context_window_tokens_snapshot = 8_000
    assert_not @run.valid?
    assert_includes @run.errors[:base], "Context budget snapshot must be either complete or absent"

    @run.assign_attributes(safe_snapshot.merge(estimated_input_tokens: 3_000))
    assert @run.valid?

    @run.estimated_input_tokens = 3_001
    assert_not @run.valid?
    assert_includes @run.errors[:base], "Context budget snapshot exceeds the context window"

    @run.assign_attributes(safe_snapshot.merge(estimated_input_tokens: -1))
    assert_not @run.valid?
    assert_includes @run.errors[:estimated_input_tokens], "must not be negative"
  end

  test "PostgreSQL rejects partial snapshots that bypass model validation" do
    assert_raises ActiveRecord::StatementInvalid do
      TranslationRun.transaction(requires_new: true) do
        @run.update_columns(context_window_tokens_snapshot: 8_000)
      end
    end
  end

  private

  def safe_snapshot
    {
      context_window_tokens_snapshot: 8_000,
      max_output_tokens_snapshot: 4_000,
      estimated_input_tokens: 3_000,
      reserved_output_tokens: 4_000,
      context_safety_margin_tokens: 1_000,
      budget_policy_version: Ai::ContextBudget::POLICY_VERSION
    }
  end
end
