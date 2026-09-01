module SourceImports
  class ProjectBinding
    PURPOSE_PREFIX = "source_import_project"

    def self.issue(source_import:, project:)
      if project && source_import.user_id != project.user_id
        raise ArgumentError, "source import and Project must have the same owner"
      end

      source_import.signed_id(purpose: purpose(project))
    end

    def self.valid?(token:, source_import:, project:)
      return false if token.blank? || (project && source_import.user_id != project.user_id)

      bound_import = SourceImport.find_signed(token, purpose: purpose(project))
      bound_import&.id == source_import.id
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      false
    end

    def self.verify!(token:, source_import:, project:)
      return true if valid?(token:, source_import:, project:)

      raise Error.new("project_binding_invalid", "This source import is not available for this workspace.")
    end

    def self.purpose(project)
      project_identity = project&.persisted? ? project.id : "new"
      "#{PURPOSE_PREFIX}:#{project_identity}"
    end
    private_class_method :purpose
  end
end
