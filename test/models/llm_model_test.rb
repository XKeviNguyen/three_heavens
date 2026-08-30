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

  test "trims surrounding catalog metadata whitespace" do
    model = LlmModel.create!(
      gateway: "openrouter",
      provider: "  anthropic  ",
      model_identifier: "  anthropic/claude-trim-test  ",
      display_name: "  Claude Trim Test  "
    )

    assert_equal "anthropic", model.provider
    assert_equal "anthropic/claude-trim-test", model.model_identifier
    assert_equal "Claude Trim Test", model.display_name
  end

  test "accepts a canonical provider and model slug identifier" do
    assert build_openrouter_model("provider/model").valid?
  end

  test "accepts a canonical identifier with a colon suffix" do
    assert build_openrouter_model("provider/model:free").valid?
  end

  test "rejects an identifier with a nested slash" do
    model = build_openrouter_model("anthropic/claude/extra")

    assert_not model.valid?
    assert model.errors[:model_identifier].any?
  end

  test "rejects an identifier with a trailing slash" do
    model = build_openrouter_model("anthropic/claude/")

    assert_not model.valid?
    assert model.errors[:model_identifier].any?
  end

  test "rejects an identifier with a leading slash" do
    model = build_openrouter_model("/anthropic/claude")

    assert_not model.valid?
    assert model.errors[:model_identifier].any?
  end

  test "rejects an identifier without a provider segment" do
    model = build_openrouter_model("/model")

    assert_not model.valid?
    assert model.errors[:model_identifier].any?
  end

  test "rejects an identifier without a model slug" do
    model = build_openrouter_model("provider/")

    assert_not model.valid?
    assert model.errors[:model_identifier].any?
  end

  test "existing repository model identifiers remain valid" do
    LlmModel.find_each do |model|
      assert model.valid?, "Expected #{model.model_identifier.inspect} to remain valid"
    end
  end

  test "validates metadata lengths and OpenRouter identifier format" do
    model = LlmModel.new(
      gateway: "openrouter",
      provider: "p" * (LlmModel::PROVIDER_MAX_LENGTH + 1),
      model_identifier: "not an identifier?token=value",
      display_name: "n" * (LlmModel::DISPLAY_NAME_MAX_LENGTH + 1)
    )

    assert_not model.valid?
    assert model.errors[:provider].any?
    assert model.errors[:model_identifier].any?
    assert model.errors[:display_name].any?
  end

  test "validates bounded context capabilities and output below context" do
    model = build_openrouter_model("provider/capability")
    model.context_window_tokens = 64_000
    model.max_output_tokens = 8_000
    assert model.valid?

    model.max_output_tokens = 64_000
    assert_not model.valid?
    assert_includes model.errors[:max_output_tokens], "must be smaller than the context window"

    model.context_window_tokens = LlmModel::MAX_CONTEXT_WINDOW_TOKENS + 1
    assert_not model.valid?

    model.context_window_tokens = 64_000
    model.max_output_tokens = nil
    assert_not model.valid?
    assert_includes model.errors[:base], "Context window and maximum output tokens must be configured together"
  end

  test "rejects a credential-like OpenRouter model identifier" do
    model = LlmModel.new(
      gateway: "openrouter",
      provider: "anthropic",
      model_identifier: "anthropic/sk-or-v1-abcdefghijklmnop",
      display_name: "Unsafe identifier"
    )

    assert_not model.valid?
    assert_includes model.errors[:model_identifier], "must not contain credentials"
  end

  test "allows changing an unused model identifier" do
    model = create_catalog_model("unused")

    assert model.update(model_identifier: "test/unused-renamed")
    assert_equal "test/unused-renamed", model.reload.model_identifier
  end

  test "rejects direct identifier updates after translation history" do
    model = llm_models(:openrouter_claude)

    assert_not model.update(model_identifier: "anthropic/rewritten")
    assert_includes model.errors[:model_identifier], "cannot be changed after the model has historical usage"
    assert_equal "anthropic/claude-test", model.reload.model_identifier
  end

  test "rejects direct identifier updates after reviewer history" do
    model = create_catalog_model("reviewer")
    review_round = experiments(:one).create_review_round!(status: :running)
    review_round.review_runs.create!(reviewer_llm_model: model)

    assert_not model.update(model_identifier: "test/reviewer-rewritten")
    assert_includes model.errors[:model_identifier], "cannot be changed after the model has historical usage"
  end

  test "rejects direct identifier updates after judge history" do
    model = create_catalog_model("judge")
    review_round = experiments(:one).create_review_round!(status: :running)
    judge_round = review_round.create_judge_round!(status: :running)
    judge_round.judge_runs.create!(judge_llm_model: model)

    assert_not model.update(model_identifier: "test/judge-rewritten")
    assert_includes model.errors[:model_identifier], "cannot be changed after the model has historical usage"
  end

  test "allows safe metadata updates after historical usage" do
    model = llm_models(:openrouter_claude)

    assert model.update(provider: "Anthropic PBC", display_name: "Claude Renamed")
    assert_equal "Anthropic PBC", model.reload.provider
    assert_equal "Claude Renamed", model.display_name
  end

  private

  def build_openrouter_model(identifier)
    LlmModel.new(
      gateway: "openrouter",
      provider: "test-provider",
      model_identifier: identifier,
      display_name: "Identifier test"
    )
  end

  def create_catalog_model(suffix)
    LlmModel.create!(
      gateway: "openrouter",
      provider: "test-provider",
      model_identifier: "test/#{suffix}",
      display_name: "Test #{suffix}"
    )
  end
end
