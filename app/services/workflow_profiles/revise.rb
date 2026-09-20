module WorkflowProfiles
  class Revise
    class StaleRevisionError < StandardError; end

    def self.call(workflow_profile:, expected_version:, attributes:)
      WorkflowProfile.transaction do
        workflow_profile.lock!
        current_version = workflow_profile.current_revision.version
        unless integer_version(expected_version) == current_version
          raise StaleRevisionError, "This profile changed while you were editing it. Review the latest revision and try again."
        end

        revision = BuildRevision.call(
          workflow_profile: workflow_profile,
          version: current_version + 1,
          attributes: attributes
        )
        revision.save!
        workflow_profile.update!(current_revision: revision)
        revision
      end
    end

    def self.integer_version(value)
      Integer(value, exception: false)
    end
    private_class_method :integer_version
  end
end
