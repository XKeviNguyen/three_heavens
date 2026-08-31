class GlossaryEntry < ApplicationRecord
  belongs_to :glossary_revision, inverse_of: :entries

  validates :position, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :glossary_revision_id }
  validates :source_term, presence: true, length: { maximum: 200 }, uniqueness: { scope: :glossary_revision_id }
  validates :preferred_target_term, presence: true, length: { maximum: 200 }
  validates :note, length: { maximum: 500 }, allow_blank: true

  before_validation :normalize_values
  before_update :prevent_mutation
  before_destroy :prevent_destruction

  private

  def normalize_values
    self.source_term = source_term.to_s.strip
    self.preferred_target_term = preferred_target_term.to_s.strip
    self.note = note.to_s.strip.presence
  end

  def prevent_mutation
    errors.add(:base, "Glossary entries are immutable")
    throw :abort
  end

  def prevent_destruction
    errors.add(:base, "Glossary entries cannot be deleted")
    throw :abort
  end
end
