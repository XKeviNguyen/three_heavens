class TranslationWorkspace
  include ActiveModel::Model

  attr_accessor :project_name,
                :user,
                :source_language,
                :target_language,
                :document_title,
                :source_text,
                :source_import,
                :source_import_id,
                :experiment_name,
                :instruction_prompt,
                :model_ids

  attr_reader :document, :experiment, :project

  validate :validate_workspace_records
  validate :validate_model_selection
  validate :validate_source_import

  def initialize(attributes = {}, start_service: TranslationExperiments::Start, clock: -> { Time.current })
    @start_service = start_service
    @clock = clock
    super(attributes)
    self.model_ids = [] if model_ids.nil?
    self.source_import_id ||= source_import&.id
  end

  def submit
    return false unless valid?

    ActiveRecord::Base.transaction do
      project.save!
      locked_import = lock_source_import
      if locked_import
        SourceImports::Consume.apply!(source_import: locked_import, document: document, at: current_time)
      end
      document.save!
      experiment.save!
      SourceImports::Consume.finish!(source_import: locked_import, document: document) if locked_import
      @start_service.call(
        experiment: experiment,
        llm_models: @llm_models
      )
    end

    true
  rescue ActiveRecord::RecordInvalid,
         TranslationExperiments::Start::Error,
         SourceImports::Error => error
    if error.is_a?(SourceImports::Error)
      errors.add(:source_import_id, error.message)
      return false
    end
    errors.add(:base, "The translation experiment could not be started. Please review the form and try again.")
    false
  end

  private

  RECORD_ATTRIBUTE_MAPPINGS = {
    project: {
      name: :project_name,
      source_language: :source_language,
      target_language: :target_language
    },
    document: {
      title: :document_title,
      source_text: :source_text
    },
    experiment: {
      name: :experiment_name,
      instruction_prompt: :instruction_prompt
    }
  }.freeze

  def build_workspace_records
    @project = Project.new(
      user: user,
      name: project_name,
      source_language: source_language,
      target_language: target_language
    )
    @document = @project.documents.build(
      title: document_title,
      source_text: source_text
    )
    @experiment = @document.experiments.build(
      name: experiment_name,
      instruction_prompt: instruction_prompt
    )
  end

  def validate_workspace_records
    build_workspace_records

    RECORD_ATTRIBUTE_MAPPINGS.each do |record_name, attribute_mapping|
      record = public_send(record_name)
      next if record.valid?

      record.errors.each do |error|
        form_attribute = attribute_mapping.fetch(error.attribute, :base)
        errors.add(form_attribute, error.message)
      end
    end
  end

  def validate_model_selection
    selected_ids = Ai::UsageLimits.normalize_model_ids(
      model_ids,
      maximum: Ai::UsageLimits::MAX_TRANSLATION_MODELS,
      label: "Translation models"
    )
    @llm_models = LlmModel.active_openrouter.where(id: selected_ids).order(:id).to_a

    return if @llm_models.map(&:id) == selected_ids.sort

    errors.add(:model_ids, "contain an inactive or unsupported model")
  rescue Ai::UsageLimits::InvalidSelection => error
    errors.add(:model_ids, error.message)
  end

  def validate_source_import
    return if source_import_id.blank?

    if source_import.nil? || source_import.user_id != user&.id
      errors.add(:source_import_id, "is not available")
    elsif !source_import.available?(at: current_time)
      errors.add(:source_import_id, "is no longer available")
    end
  end

  def lock_source_import
    return if source_import_id.blank?

    user.source_imports.lock.find(source_import_id)
  end

  def current_time
    @clock.call
  end
end
