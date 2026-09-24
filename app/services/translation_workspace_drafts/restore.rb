module TranslationWorkspaceDrafts
  class Restore
    Result = Data.define(:attributes, :configuration_notice, :import_notice)

    def self.call(draft:, user:, project:)
      new(draft:, user:, project:).call
    end

    def initialize(draft:, user:, project:)
      @draft = draft
      @user = user
      @project = project
    end

    def call
      attributes = draft.payload.symbolize_keys
      removed = false
      import_notice = nil
      source_import_id = attributes[:source_import_id]
      if source_import_id.present?
        source_import = user.source_imports.find_by(id: source_import_id)
        if source_import&.available?
          attributes[:source_import_project_token] = SourceImports::ProjectBinding.issue(source_import:, project:)
        else
          attributes.delete(:source_import_id)
          removed = true
          import_notice = "The original upload is no longer attached. Your reviewed source text remains."
        end
      end

      source_language = project&.source_language || attributes[:source_language]
      target_language = project&.target_language || attributes[:target_language]

      if attributes[:glossary_revision_id].present?
        revision = GlossaryRevision.joins(:glossary).where(glossaries: { user_id: user.id, active: true })
          .find_by(id: attributes[:glossary_revision_id])
        unless revision && revision.glossary.current_revision_id == revision.id &&
            TranslationLanguagePair.matches?(revision, source_language:, target_language:)
          attributes.delete(:glossary_revision_id)
          removed = true
        end
      end

      if attributes[:methodology_profile_revision_id].present?
        revision = MethodologyProfileRevision.joins(:methodology_profile)
          .where(methodology_profiles: { user_id: user.id, active: true })
          .find_by(id: attributes[:methodology_profile_revision_id])
        unless revision && revision.methodology_profile.current_revision_id == revision.id &&
            TranslationLanguagePair.matches?(revision, source_language:, target_language:)
          attributes.delete(:methodology_profile_revision_id)
          removed = true
        end
      end

      if attributes[:workflow_profile_revision_id].present?
        revision = WorkflowProfileRevision.joins(:workflow_profile)
          .where(workflow_profiles: { user_id: user.id, active: true })
          .find_by(id: attributes[:workflow_profile_revision_id])
        unless revision && revision.workflow_profile.current_revision_id == revision.id && revision.routing_eligible?
          attributes.delete(:workflow_profile_revision_id)
          attributes[:workflow_mode] = "manual"
          removed = true
        end
      end

      if attributes[:translation_reference_revision_ids].present?
        ids = attributes[:translation_reference_revision_ids]
        valid_ids = TranslationReferenceRevision.joins(:translation_reference)
          .where(translation_references: { user_id: user.id, active: true }, id: ids)
          .includes(:translation_reference).select do |revision|
            revision.translation_reference.current_revision_id == revision.id &&
              TranslationLanguagePair.matches?(revision, source_language:, target_language:)
          end.map { |revision| revision.id.to_s }
        attributes[:translation_reference_revision_ids] = ids & valid_ids
        removed ||= attributes[:translation_reference_revision_ids].length != ids.length
      end

      if attributes[:model_ids].present?
        ids = attributes[:model_ids]
        valid_ids = LlmModel.active_openrouter.where(id: ids).pluck(:id).map(&:to_s)
        attributes[:model_ids] = ids & valid_ids
        removed ||= attributes[:model_ids].length != ids.length
      end

      if attributes[:model_identifiers].present?
        identifiers = attributes[:model_identifiers]
        inactive = LlmModel.where(gateway: "openrouter", model_identifier: identifiers, active: false)
          .pluck(:model_identifier)
        attributes[:model_identifiers] = identifiers - inactive
        removed ||= attributes[:model_identifiers].length != identifiers.length
      end

      Result.new(
        attributes:,
        configuration_notice: removed ? "Some saved configuration is no longer available. Review the remaining selections." : nil,
        import_notice:
      )
    end

    private

    attr_reader :draft, :user, :project
  end
end
