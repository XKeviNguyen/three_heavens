require "test_helper"

class LlmModelTest < ActiveSupport::TestCase
  test "is valid with required attributes" do
    model = LlmModel.new(
      gateway: "openrouter",
      provider: "anthropic",
      model_identifier: "anthropic/claude-new-test",
      display_name: "Claude New Test"
    )

    assert model.valid?
  end

  test "requires gateway" do
    model = LlmModel.new(
      provider: "anthropic",
      model_identifier: "anthropic/claude-gateway-test",
      display_name: "Claude Test"
    )

    assert_not model.valid?
  end

  test "requires provider" do
    model = LlmModel.new(
      gateway: "openrouter",
      model_identifier: "anthropic/claude-provider-test",
      display_name: "Claude Test"
    )

    assert_not model.valid?
  end

  test "requires model identifier" do
    model = LlmModel.new(
      gateway: "openrouter",
      provider: "anthropic",
      display_name: "Claude Test"
    )

    assert_not model.valid?
  end

  test "requires display name" do
    model = LlmModel.new(
      gateway: "openrouter",
      provider: "anthropic",
      model_identifier: "anthropic/claude-display-test"
    )

    assert_not model.valid?
  end

  test "model identifier is unique within a gateway" do
    existing = llm_models(:openrouter_claude)

    duplicate = LlmModel.new(
      gateway: existing.gateway,
      provider: existing.provider,
      model_identifier: existing.model_identifier,
      display_name: "Duplicate Claude"
    )

    assert_not duplicate.valid?
    assert duplicate.errors[:model_identifier].any?
  end
end
