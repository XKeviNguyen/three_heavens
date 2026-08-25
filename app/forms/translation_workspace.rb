class TranslationWorkspace
  include ActiveModel::Model

  attr_accessor :project_name,
                :source_language,
                :target_language,
                :document_title,
                :source_text,
                :experiment_name,
                :instruction_prompt,
                :model_ids

  attr_reader :document, :experiment, :project

  validate :validate_workspace_records
  validate :validate_model_selection

  def initialize(attributes = {}, start_service: TranslationExperiments::Start)
    @start_service = start_service
    super(attributes)
    self.model_ids = Array(model_ids)
  end

  def submit
    return false unless valid?

    ActiveRecord::Base.transaction do
      project.save!
      document.save!
      experiment.save!
      @start_service.call(
        experiment: experiment,
        llm_models: @llm_models
      )
    end

    true
  rescue ActiveRecord::RecordInvalid,
         TranslationExperiments::Start::Error
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
    submitted_ids = model_ids.filter_map do |model_id|
      value = model_id.to_s
      value if value.present?
    end

    if submitted_ids.empty?
      errors.add(:model_ids, "select at least one active OpenRouter model")
      return
    end

    unless submitted_ids.all? { |model_id| model_id.match?(/\A[1-9]\d*\z/) }
      errors.add(:model_ids, "contain an invalid model selection")
      return
    end

    selected_ids = submitted_ids.map(&:to_i).uniq
    @llm_models = LlmModel.active_openrouter.where(id: selected_ids).order(:id).to_a

    return if @llm_models.map(&:id) == selected_ids.sort

    errors.add(:model_ids, "contain an inactive or unsupported model")
  end
end
