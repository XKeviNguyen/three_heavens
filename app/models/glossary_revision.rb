class GlossaryRevision < ApplicationRecord
  MAXIMUM_ENTRIES = 100

  belongs_to :glossary, inverse_of: :revisions
  has_one :current_for_glossary, class_name: "Glossary", foreign_key: :current_revision_id,
           dependent: :restrict_with_error, inverse_of: :current_revision
  has_many :entries, -> { order(:position) }, class_name: "GlossaryEntry", dependent: :restrict_with_error, inverse_of: :glossary_revision
  has_many :experiments, dependent: :restrict_with_error

  validates :version, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :glossary_id }
  validates :name, presence: true, length: { maximum: 150 }
  validates :description, length: { maximum: 500 }, allow_blank: true
  validates :source_language, :target_language, presence: true, length: { maximum: 100 }
  validates :configuration_digest, presence: true, length: { is: 64 }
  validates_associated :entries
  validate :entry_count_is_bounded
  validate :source_terms_are_unique

  before_validation :normalize_values
  before_validation :assign_configuration_digest
  before_update :prevent_mutation
  before_destroy :prevent_destruction

  def language_pair_matches?(source_language:, target_language:)
    Glossaries::LanguagePair.matches?(self, source_language:, target_language:)
  end

  def save_initial_entry_set!
    @accepting_initial_entries = true
    save!
    self.class.connection.execute("SET CONSTRAINTS seal_glossary_revision_entry_set_trigger IMMEDIATE")
    self.class.connection.execute("SET CONSTRAINTS seal_glossary_revision_entry_set_trigger DEFERRED")
  ensure
    @accepting_initial_entries = false
  end

  def accepting_initial_entries?
    @accepting_initial_entries == true
  end

  private

  def normalize_values
    self.name = name.to_s.strip
    self.description = description.to_s.strip.presence
    self.source_language = source_language.to_s.strip
    self.target_language = target_language.to_s.strip
    entries.each do |entry|
      entry.source_term = entry.source_term.to_s.strip
      entry.preferred_target_term = entry.preferred_target_term.to_s.strip
      entry.note = entry.note.to_s.strip.presence
    end
  end

  def assign_configuration_digest
    return if entries.empty?

    self.configuration_digest = Glossaries::ConfigurationDigest.call(self)
  end

  def entry_count_is_bounded
    errors.add(:entries, "must include 1-#{MAXIMUM_ENTRIES} entries") unless entries.size.between?(1, MAXIMUM_ENTRIES)
  end

  def source_terms_are_unique
    return if entries.map(&:source_term).uniq.size == entries.size

    errors.add(:entries, "cannot contain duplicate source terms")
  end

  def prevent_mutation
    errors.add(:base, "Glossary revisions are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Glossary revisions cannot be deleted")
    throw :abort
  end
end
