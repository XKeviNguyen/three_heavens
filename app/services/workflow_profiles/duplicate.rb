module WorkflowProfiles
  class Duplicate
    def self.call(workflow_profile:)
      revision = workflow_profile.current_revision
      attributes = {
        "name" => "Copy of #{revision.name}".truncate(150),
        "description" => revision.description,
        "completion_mode" => revision.completion_mode
      }
      WorkflowProfileModelSelection::ROLES.each do |role|
        attributes["#{role}_ids"] = revision.selections_for(role).map(&:llm_model_id)
      end
      Create.call(user: workflow_profile.user, attributes: attributes)
    end
  end
end
