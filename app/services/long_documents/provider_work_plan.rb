require "digest"
require "json"

module LongDocuments
  class ProviderWorkPlan
    Preview = Data.define(:segment_count)

    def self.call(execution_plan:, role_models:, source_character_count:)
      segment_count = execution_plan&.segment_count || 1
      roles = role_models.to_h do |role, models|
        model_snapshots = models.map do |model|
          {
            "llm_model_id" => model.id,
            **Ai::ContextBudget.capability_snapshot(
              model: model,
              source_character_count: source_character_count
            )
          }
        end
        [
          role,
          {
            "logical_run_count" => models.size,
            "provider_request_slots" => models.size * segment_count,
            "models" => model_snapshots
          }
        ]
      end
      initial_slots = roles.values.sum { |role| role.fetch("provider_request_slots") }
      {
        "version" => "provider-work-plan-v2",
        "segment_count" => segment_count,
        "segmented" => execution_plan.present?,
        "roles" => roles,
        "authorized_initial_provider_request_slots" => initial_slots,
        "built_in_retry_policy" => {
          "version" => Ai::ProviderRetryPolicy::VERSION,
          "maximum_attempts_per_slot" => Ai::ProviderRetryPolicy::MAX_ATTEMPTS_PER_AUTHORIZATION
        },
        "maximum_automatic_provider_requests" => initial_slots * Ai::ProviderRetryPolicy::MAX_ATTEMPTS_PER_AUTHORIZATION
      }
    end

    def self.capability_snapshots(work_plan, role)
      work_plan.fetch("roles").fetch(role).fetch("models").to_h do |snapshot|
        [ snapshot.fetch("llm_model_id"), snapshot.slice("context_window_tokens", "max_output_tokens") ]
      end
    end

    def self.digest(work_plan)
      Digest::SHA256.hexdigest(JSON.generate(work_plan))
    end
  end
end
