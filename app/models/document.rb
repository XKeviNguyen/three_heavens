class Document < ApplicationRecord
  belongs_to :project

  has_many :experiments, dependent: :restrict_with_error

  validates :title, presence: true, length: { maximum: 255 }
  validates :source_text, presence: true
end
