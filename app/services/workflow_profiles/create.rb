module WorkflowProfiles
  class Create
    def self.call(user:, attributes:, active: true)
      WorkflowProfile.transaction do
        profile = user.workflow_profiles.create!(active: active)
        revision = BuildRevision.call(workflow_profile: profile, version: 1, attributes: attributes)
        revision.save!
        profile.update!(current_revision: revision)
        profile
      end
    end
  end
end
