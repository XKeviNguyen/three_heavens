module WorkflowProfiles
  class ChangeStatus
    class IneligibleConfigurationError < StandardError; end

    def self.activate(workflow_profile:)
      workflow_profile.with_lock do
        unless workflow_profile.current_revision.routing_eligible?
          raise IneligibleConfigurationError,
                "This profile references unavailable or changed models. Create a new revision before activating it."
        end
        workflow_profile.update!(active: true)
      end
    end

    def self.deactivate(workflow_profile:)
      workflow_profile.with_lock { workflow_profile.update!(active: false) }
    end
  end
end
