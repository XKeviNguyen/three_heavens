module SourceImports
  class ProjectBinding
    PURPOSE_PREFIX = "source_import_project"

    def self.issue(source_import:, project:)
      unless source_import.user_id == project.user_id
        raise ArgumentError, "source import and Project must have the same owner"
      end

      project.signed_id(purpose: purpose(source_import))
    end

    def self.valid?(token:, source_import:, project:)
      return false if token.blank? || source_import.user_id != project.user_id

      bound_project = Project.find_signed(token, purpose: purpose(source_import))
      bound_project&.id == project.id
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      false
    end

    def self.verify!(token:, source_import:, project:)
      return true if valid?(token:, source_import:, project:)

      raise Error.new("project_binding_invalid", "This source import is not available for this Project.")
    end

    def self.purpose(source_import)
      "#{PURPOSE_PREFIX}:#{source_import.id}"
    end
    private_class_method :purpose
  end
end
