class Document < ApplicationRecord
  belongs_to :project

  has_many :experiments, dependent: :restrict_with_error
  has_one :source_import, foreign_key: :resulting_document_id, dependent: :restrict_with_error
  has_one_attached :source_file

  enum :source_kind, {
    pasted_text: "pasted_text",
    uploaded_file: "uploaded_file"
  }, validate: true

  validates :title, presence: true, length: { maximum: 255 }
  validates :source_text,
            presence: true,
            length: { maximum: Ai::UsageLimits::MAX_SOURCE_CHARACTERS }
  validates :source_format, inclusion: { in: SourceImports::Limits::FORMATS }, allow_nil: true
  validates :original_filename, :detected_content_type, length: { maximum: 255 }, allow_nil: true
  validates :original_byte_size,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: SourceImports::Limits::MAX_UPLOAD_BYTES
            },
            allow_nil: true
  validates :source_sha256, format: { with: /\A\h{64}\z/ }, allow_nil: true
  validates :extraction_version, length: { maximum: 100 }, allow_nil: true

  validate :uploaded_provenance_is_complete

  private

  def uploaded_provenance_is_complete
    return unless uploaded_file?

    %i[source_format original_filename detected_content_type original_byte_size source_sha256 extraction_version].each do |attribute|
      errors.add(attribute, "must be present for an uploaded source") if public_send(attribute).blank?
    end
    errors.add(:source_file, "must be attached for an uploaded source") unless source_file.attached?
  end
end
