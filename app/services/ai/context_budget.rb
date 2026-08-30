require "json"

module Ai
  class ContextBudget
    POLICY_VERSION = "conservative-bytes-v1"
    SAFETY_MARGIN_TOKENS = 1_024
    CONSERVATIVE_CONTEXT_TOKENS = 16_384
    CONSERVATIVE_MAX_OUTPUT_TOKENS = 4_096
    SMALL_DOCUMENT_FALLBACK_CHARACTERS = 8_000
    STAGE_OUTPUT_TOKENS = {
      translation: 4_096,
      review: 4_096,
      judge: 4_096,
      finalization: 4_096
    }.freeze
    STRUCTURED_SCHEMA_NAMES = {
      review: "blind_translation_review",
      judge: "blind_translation_judgment",
      finalization: "final_translation_refinement"
    }.freeze

    class Error < Ai::OpenRouterClient::PermanentError; end

    Result = Data.define(
      :context_window_tokens,
      :max_output_tokens,
      :estimated_input_tokens,
      :reserved_output_tokens,
      :safety_margin_tokens,
      :policy_version
    ) do
      def snapshot_attributes
        {
          context_window_tokens_snapshot: context_window_tokens,
          max_output_tokens_snapshot: max_output_tokens,
          estimated_input_tokens: estimated_input_tokens,
          reserved_output_tokens: reserved_output_tokens,
          context_safety_margin_tokens: safety_margin_tokens,
          budget_policy_version: policy_version
        }
      end
    end

    def self.call(model:, system_prompt:, user_prompt:, response_schema: nil, stage:, source_character_count:,
                  capability_snapshot: nil)
      capabilities = capability_snapshot || capabilities_for(model, source_character_count: source_character_count)
      reserved = [ STAGE_OUTPUT_TOKENS.fetch(stage.to_sym), capability_value(capabilities, :max_output_tokens) ].min
      options = { max_tokens: reserved }
      if response_schema
        options[:response_format] = {
          type: "json_schema",
          json_schema: {
            name: STRUCTURED_SCHEMA_NAMES.fetch(stage.to_sym),
            strict: true,
            schema: response_schema
          }
        }
        options[:provider] = { require_parameters: true }
      end
      serialized = Ai::OpenRouterClient.serialize_request(
        model_identifier: model.model_identifier,
        messages: [
          { role: "system", content: system_prompt.to_s },
          { role: "user", content: user_prompt.to_s }
        ],
        **options
      )
      estimated = estimate_tokens(serialized)
      context = capability_value(capabilities, :context_window_tokens)
      if estimated + reserved + SAFETY_MARGIN_TOKENS > context
        raise Error.new(
          "The selected model cannot safely fit the planned #{stage} request",
          code: "context_budget_exceeded"
        )
      end

      Result.new(
        context_window_tokens: context,
        max_output_tokens: capability_value(capabilities, :max_output_tokens),
        estimated_input_tokens: estimated,
        reserved_output_tokens: reserved,
        safety_margin_tokens: SAFETY_MARGIN_TOKENS,
        policy_version: POLICY_VERSION
      )
    end

    def self.estimate_tokens(value)
      # OpenRouter models may use different tokenizers. Counting one token per
      # two UTF-8 bytes deliberately overestimates ordinary Latin text and also
      # remains conservative for multibyte scripts and JSON escaping.
      (value.to_s.bytesize.fdiv(2)).ceil + 64
    end

    def self.capability_snapshot(model:, source_character_count:)
      capabilities_for(model, source_character_count: source_character_count).stringify_keys
    end

    def self.capability_value(capabilities, key)
      Integer(capabilities[key] || capabilities[key.to_s])
    end
    private_class_method :capability_value

    def self.capabilities_for(model, source_character_count:)
      if model.context_window_tokens && model.max_output_tokens
        return {
          context_window_tokens: model.context_window_tokens,
          max_output_tokens: model.max_output_tokens
        }
      end

      if source_character_count <= SMALL_DOCUMENT_FALLBACK_CHARACTERS
        return {
          context_window_tokens: CONSERVATIVE_CONTEXT_TOKENS,
          max_output_tokens: CONSERVATIVE_MAX_OUTPUT_TOKENS
        }
      end

      raise Error.new(
        "Model context capability is not configured",
        code: "model_capability_unconfigured"
      )
    end
    private_class_method :capabilities_for
  end
end
