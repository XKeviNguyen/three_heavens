module WorkflowProfiles
  class RoutingModels
    class ConfigurationUnavailableError < StandardError; end

    def self.call(revision:, role:)
      selections = revision.selections_for(role)
      models_by_id = LlmModel.lock.where(id: selections.map(&:llm_model_id)).index_by(&:id)
      models = selections.map do |selection|
        model = models_by_id[selection.llm_model_id]
        unless model&.active? &&
               model.gateway == "openrouter" &&
               model.gateway == selection.gateway_snapshot &&
               model.provider == selection.provider_snapshot &&
               model.model_identifier == selection.model_identifier_snapshot
          raise ConfigurationUnavailableError,
                "The configured #{role} models are no longer available with their authorized routing identities."
        end
        model
      end
      models
    end
  end
end
