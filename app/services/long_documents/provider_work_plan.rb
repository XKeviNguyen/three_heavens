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
      {
        "version" => "provider-work-plan-v1",
        "segment_count" => segment_count,
        "segmented" => execution_plan.present?,
        "roles" => roles,
        "authorized_initial_provider_request_slots" => roles.values.sum { |role| role.fetch("provider_request_slots") }
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
