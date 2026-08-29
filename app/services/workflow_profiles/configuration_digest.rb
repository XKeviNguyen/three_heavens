require "digest"
require "json"

module WorkflowProfiles
  class ConfigurationDigest
    def self.call(revision)
      selections = revision.model_selections.sort_by { |selection| [ selection.role, selection.position ] }
      canonical = {
        "completion_mode" => revision.completion_mode,
        "selections" => selections.map do |selection|
          {
            "role" => selection.role,
            "position" => selection.position,
            "gateway" => selection.gateway_snapshot,
            "provider" => selection.provider_snapshot,
            "model_identifier" => selection.model_identifier_snapshot
          }
        end
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical))
    end
  end
end
