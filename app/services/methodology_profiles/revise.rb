module MethodologyProfiles
  class Revise
    class StaleRevisionError < StandardError; end

    def self.call(methodology_profile:, expected_version:, attributes:)
      MethodologyProfile.transaction do
        methodology_profile.lock!
        current_version = methodology_profile.current_revision.version
        unless Integer(expected_version, exception: false) == current_version
          raise StaleRevisionError,
                "This methodology changed while you were editing it. Review the latest revision and try again."
        end

        revision = BuildRevision.call(
          methodology_profile: methodology_profile,
          version: current_version + 1,
          attributes: attributes
        )
        revision.save!
        methodology_profile.update!(current_revision: revision)
        revision
      end
    end
  end
end
