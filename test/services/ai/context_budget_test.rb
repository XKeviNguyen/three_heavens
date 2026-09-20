require "test_helper"

class Ai::ContextBudgetTest < ActiveSupport::TestCase
  setup do
    @model = LlmModel.new(
      gateway: "openrouter",
      provider: "test",
      model_identifier: "test/context-budget",
      display_name: "Context budget",
      context_window_tokens: 12_000,
      max_output_tokens: 4_096
    )
  end

  test "budgets the serialized request schema output reserve and safety margin" do
    result = Ai::ContextBudget.call(
      model: @model,
      system_prompt: "System",
      user_prompt: "語🙂" * 100,
      response_schema: { type: "object", properties: { answer: { type: "string" } } },
      stage: :review,
      source_character_count: 200
    )

    assert_operator result.estimated_input_tokens, :>, 200
    assert_equal 4_096, result.reserved_output_tokens
    assert_equal 1_024, result.safety_margin_tokens
    assert_equal Ai::ContextBudget::POLICY_VERSION, result.policy_version
  end

  test "counts each serialized UTF-8 byte plus framing allowance across scripts" do
    samples = {
      ascii: "Plain text",
      japanese: "神は世を愛された。",
      vietnamese: "Đức Chúa Trời yêu thương.",
      emoji: "🙏🏽✨"
    }

    samples.each_value do |sample|
      serialized = Ai::OpenRouterClient.serialize_request(
        model_identifier: @model.model_identifier,
        messages: [ { role: "system", content: "S" }, { role: "user", content: sample } ],
        max_tokens: 4_096
      )

      assert_equal serialized.bytesize + 64, Ai::ContextBudget.estimate_tokens(serialized)
    end
  end

  test "uses exactly the structured request options sent to the provider" do
    schema = { type: "object", properties: { answer: { type: "string" } } }
    result = Ai::ContextBudget.call(
      model: @model,
      system_prompt: "Review",
      user_prompt: "Candidate",
      response_schema: schema,
      stage: :review,
      source_character_count: 9
    )
    serialized = Ai::OpenRouterClient.serialize_request(
      model_identifier: @model.model_identifier,
      messages: [ { role: "system", content: "Review" }, { role: "user", content: "Candidate" } ],
      max_tokens: 4_096,
      response_format: {
        type: "json_schema",
        json_schema: {
          name: "blind_translation_review",
          strict: true,
          schema: schema
        }
      },
      provider: { require_parameters: true }
    )
    payload = JSON.parse(serialized)

    assert_equal Ai::ContextBudget.estimate_tokens(serialized), result.estimated_input_tokens
    assert_equal [ { "id" => "context-compression", "enabled" => false } ], payload.fetch("plugins")
  end

  test "allows the exact safe boundary and fails one unit beyond it" do
    serialized = Ai::OpenRouterClient.serialize_request(
      model_identifier: @model.model_identifier,
      messages: [ { role: "system", content: "S" }, { role: "user", content: "U" } ],
      max_tokens: 4_096
    )
    base = Ai::ContextBudget.estimate_tokens(serialized)
    @model.context_window_tokens = base + 4_096 + Ai::ContextBudget::SAFETY_MARGIN_TOKENS

    result = Ai::ContextBudget.call(
      model: @model,
      system_prompt: "S",
      user_prompt: "U",
      stage: :translation,
      source_character_count: 1
    )
    assert_equal @model.context_window_tokens, result.estimated_input_tokens +
      result.reserved_output_tokens + result.safety_margin_tokens

    @model.context_window_tokens -= 1

    error = assert_raises(Ai::ContextBudget::Error) do
      Ai::ContextBudget.call(
        model: @model,
        system_prompt: "S",
        user_prompt: "U",
        stage: :translation,
        source_character_count: 1
      )
    end
    assert_equal "context_budget_exceeded", error.code
  end

  test "requires the full stage output reserve" do
    assert_equal 4_096, Ai::ContextBudget.call(
      model: @model,
      system_prompt: "S",
      user_prompt: "U",
      stage: :translation,
      source_character_count: 1
    ).reserved_output_tokens

    @model.max_output_tokens = 4_095
    error = assert_raises(Ai::ContextBudget::Error) do
      Ai::ContextBudget.call(
        model: @model,
        system_prompt: "S",
        user_prompt: "U",
        stage: :translation,
        source_character_count: 1
      )
    end
    assert_equal "model_output_capability_insufficient", error.code
  end

  test "fails a low-context model" do
    @model.context_window_tokens = 5_000

    error = assert_raises(Ai::ContextBudget::Error) do
      Ai::ContextBudget.call(
        model: @model,
        system_prompt: "S" * 200,
        user_prompt: "U" * 200,
        stage: :translation,
        source_character_count: 200
      )
    end
    assert_equal "context_budget_exceeded", error.code
  end

  test "does not rewrite a persisted snapshot from an older policy" do
    run = Struct.new(
      :context_window_tokens_snapshot,
      :max_output_tokens_snapshot,
      :budget_policy_version,
      keyword_init: true
    ).new(
      context_window_tokens_snapshot: 12_000,
      max_output_tokens_snapshot: 4_096,
      budget_policy_version: "conservative-bytes-v1"
    )

    result = Ai::RunContextBudget.call(
      run: run,
      model: @model,
      prompt: { system_prompt: "S", user_prompt: "U" },
      stage: :translation,
      source_character_count: 1
    )

    assert_equal Ai::ContextBudget::POLICY_VERSION, result.policy_version
    assert_equal "conservative-bytes-v1", run.budget_policy_version
  end

  test "allows conservative small-document fallback and rejects unknown long-document capability" do
    @model.context_window_tokens = nil
    @model.max_output_tokens = nil

    assert Ai::ContextBudget.call(
      model: @model,
      system_prompt: "Translate",
      user_prompt: "Short",
      stage: :translation,
      source_character_count: 5
    )

    error = assert_raises(Ai::ContextBudget::Error) do
      Ai::ContextBudget.call(
        model: @model,
        system_prompt: "Translate",
        user_prompt: "Segment",
        stage: :translation,
        source_character_count: 8_001
      )
    end
    assert_equal "model_capability_unconfigured", error.code
  end
end
