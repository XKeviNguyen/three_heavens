module MethodologyProfiles
  class ChangeStatus
    def self.activate(methodology_profile:)
      methodology_profile.update!(active: true)
    end

    def self.deactivate(methodology_profile:)
      methodology_profile.update!(active: false)
    end
  end
end
