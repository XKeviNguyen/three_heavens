module MethodologyProfiles
  class Create
    def self.call(user:, attributes:, active: true)
      MethodologyProfile.transaction do
        profile = user.methodology_profiles.create!(active: active)
        revision = BuildRevision.call(methodology_profile: profile, version: 1, attributes: attributes)
        revision.save!
        profile.update!(current_revision: revision)
        profile
      end
    end
  end
end
