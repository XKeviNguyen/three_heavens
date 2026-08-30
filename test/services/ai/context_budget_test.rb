require "test_helper"

class Ai::ContextBudgetTest < ActiveSupport::TestCase
  setup do
    @model = LlmModel.new(
      gateway: "openrouter",
      provider: "test",
      model_identifier: "test/context-budget",
      display_name: "Context budget",
      context_window_tokens: 8_000,
      max_output_tokens: 2_000
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
    assert_equal 2_000, result.reserved_output_tokens
    assert_equal 1_024, result.safety_margin_tokens
    assert_equal Ai::ContextBudget::POLICY_VERSION, result.policy_version
  end

  test "fails closed one unit beyond the calculated boundary" do
    serialized = Ai::OpenRouterClient.serialize_request(
      model_identifier: @model.model_identifier,
      messages: [ { role: "system", content: "S" }, { role: "user", content: "U" } ],
      max_tokens: 2_000
    )
    base = Ai::ContextBudget.estimate_tokens(serialized)
    @model.context_window_tokens = base + 2_000 + Ai::ContextBudget::SAFETY_MARGIN_TOKENS - 1

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
