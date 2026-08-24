class Project < ApplicationRecord
  has_many :documents, dependent: :restrict_with_error

  validates :name, presence: true, length: { maximum: 150 }
  validates :source_language, presence: true
  validates :target_language, presence: true
end
