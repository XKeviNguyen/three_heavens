class TranslationWorkspaceDraft < ApplicationRecord
  # Rolling seven-day expiry; the hourly production job deletes expired rows.
  RETENTION = 7.days
  MAX_PAYLOAD_BYTES = 500_000
  EDITOR_ID_FORMAT = /\A[0-9a-f]{32}\z/
  MAX_EDITOR_SEQUENCE = 2**53 - 1
  SCALAR_FIELDS = %w[
    project_name source_language target_language document_title source_text
    source_import_id experiment_name instruction_prompt workflow_mode
    workflow_profile_revision_id glossary_revision_id
    methodology_profile_revision_id guidance_preference
  ].freeze
  ARRAY_FIELDS = %w[model_ids model_identifiers translation_reference_revision_ids].freeze
  FIELDS = (SCALAR_FIELDS + ARRAY_FIELDS).freeze
  FIELD_LIMITS = {
    "project_name" => 150, "source_language" => 100, "target_language" => 100,
    "document_title" => 255, "source_text" => Ai::UsageLimits::MAX_SOURCE_CHARACTERS,
    "source_import_id" => 20, "experiment_name" => 150,
    "instruction_prompt" => Ai::UsageLimits::MAX_INSTRUCTION_CHARACTERS,
    "workflow_mode" => 16, "workflow_profile_revision_id" => 20,
    "glossary_revision_id" => 20, "methodology_profile_revision_id" => 20,
    "guidance_preference" => 100
  }.freeze

  belongs_to :user
  encrypts :workspace_payload

  validates :public_id, presence: true, uniqueness: true
  # One draft per user and context is enforced only by the unique index on
  # (user_id, context_key). An application uniqueness check would race with a
  # concurrent first save that commits between its lookup and its insert and
  # reject it as invalid; TranslationWorkspaceDrafts::Save instead resolves
  # the index violation against the draft that won.
  validates :context_key, presence: true, length: { maximum: 80 }
  validates :workspace_payload, presence: true
  validates :expires_at, presence: true
  validates :editor_id, format: { with: EDITOR_ID_FORMAT }, allow_nil: true
  validates :editor_sequence, presence: true, numericality: { only_integer: true, greater_than: 0 }, if: :editor_id

  before_validation :assign_public_id, on: :create

  scope :current, -> { where("expires_at > ?", Time.current) }

  def self.context_key(project)
    project ? "project:#{project.id}" : "new"
  end

  def self.validate_payload!(value)
    unless value.is_a?(Hash) && (value.keys - FIELDS).empty? && value.keys.all? { |key| key.is_a?(String) }
      raise ArgumentError, "Invalid workspace draft fields"
    end

    SCALAR_FIELDS.each do |field|
      next unless value.key?(field)
      item = value[field]
      unless item.is_a?(String) && item.length <= FIELD_LIMITS.fetch(field)
        raise ArgumentError, "Invalid workspace draft field"
      end
    end
    ARRAY_FIELDS.each do |field|
      next unless value.key?(field)
      items = value[field]
      maximum = field == "translation_reference_revision_ids" ? 5 : Ai::UsageLimits::MAX_TRANSLATION_MODELS
      unless items.is_a?(Array) && items.length <= maximum && items.all? { |item| item.is_a?(String) && item.length <= 200 }
        raise ArgumentError, "Invalid workspace draft selection"
      end
    end
    %w[source_import_id workflow_profile_revision_id glossary_revision_id methodology_profile_revision_id].each do |field|
      next if value[field].blank?
      raise ArgumentError, "Invalid workspace draft selection" unless value[field].match?(/\A[1-9]\d*\z/)
    end
    if value.key?("workflow_mode") && !%w[manual automatic].include?(value["workflow_mode"])
      raise ArgumentError, "Invalid workspace draft mode"
    end
    if value.key?("guidance_preference") && !TranslationGuidance::Policy::LABELS.key?(value["guidance_preference"])
      raise ArgumentError, "Invalid workspace draft guidance"
    end
    %w[model_ids translation_reference_revision_ids].each do |field|
      next unless value.key?(field)
      unless value[field].all? { |id| id.match?(/\A[1-9]\d*\z/) } && value[field].uniq == value[field]
        raise ArgumentError, "Invalid workspace draft selection"
      end
    end
    if value.key?("model_identifiers") &&
        (!value["model_identifiers"].all? { |id| id.match?(LlmModel::OPENROUTER_IDENTIFIER_FORMAT) } ||
         value["model_identifiers"].uniq != value["model_identifiers"])
      raise ArgumentError, "Invalid workspace draft model identifier"
    end
    raise ArgumentError, "Workspace draft is too large" if JSON.generate(value).bytesize > MAX_PAYLOAD_BYTES

    value
  end

  def payload
    JSON.parse(workspace_payload)
  end

  # The payload, or nil when it cannot be read: it no longer decrypts (for
  # example after the secret key base changed) or is not a valid draft.
  def readable_payload
    self.class.validate_payload!(payload)
  rescue ActiveRecord::Encryption::Errors::Decryption, JSON::ParserError, ArgumentError
    nil
  end

  # An editor is one browser page load. The editor that wrote the draft last
  # may keep writing even if it never received the latest version, because
  # every change since its own acknowledged version is its own. Anyone else
  # must name the current identity and version (optimistic concurrency).
  def writable_by?(editor_id:, public_id:, version:)
    (editor_id.present? && self.editor_id == editor_id) ||
      (self.public_id == public_id && lock_version == version)
  end

  private

  def assign_public_id
    self.public_id ||= SecureRandom.uuid
  end
end
