class SourceImport < ApplicationRecord
  AVAILABILITY_MESSAGES = {
    expired: "has expired; upload the source file again",
    already_consumed: "was already used",
    unavailable: "is no longer available; upload the source file again"
  }.freeze

  belongs_to :user
  belongs_to :resulting_document, class_name: "Document", optional: true

  has_one_attached :source_file, dependent: false

  before_destroy :remember_source_file_blob, prepend: true
  after_destroy_commit :purge_destroyed_source_file_blob

  enum :status, {
    pending: "pending",
    ready: "ready",
    failed: "failed",
    consumed: "consumed"
  }, validate: true

  validates :original_filename,
            presence: true,
            length: { maximum: SourceImports::Limits::MAX_ORIGINAL_FILENAME_CHARACTERS }
  validates :detected_content_type, length: { maximum: 255 }, allow_nil: true
  validates :imported_format, inclusion: { in: SourceImports::Limits::FORMATS }, allow_nil: true
  validates :byte_size,
            numericality: {
              only_integer: true,
              greater_than_or_equal_to: 0,
              less_than_or_equal_to: SourceImports::Limits::MAX_UPLOAD_BYTES
            },
            allow_nil: true
  validates :sha256, format: { with: /\A\h{64}\z/ }, allow_nil: true
  validates :extracted_text,
            length: { maximum: Ai::UsageLimits::MAX_SOURCE_CHARACTERS },
            allow_nil: true
  validates :failure_code, :extraction_version, length: { maximum: 100 }, allow_nil: true
  validates :failure_message, length: { maximum: 500 }, allow_nil: true
  validates :expires_at, presence: true
  validates :request_key, format: { with: SourceImports::Limits::REQUEST_KEY_FORMAT }, allow_nil: true

  scope :expired_abandoned, lambda { |cutoff = Time.current|
    where(status: %w[pending ready failed]).where(expires_at: ..cutoff)
  }

  def available?(at: Time.current)
    ready? && consumed_at.nil? && source_file.attached? && expires_at > at
  end

  def availability_failure(at: Time.current)
    return if available?(at:)
    return :already_consumed if consumed? || consumed_at.present?
    return :expired if expires_at <= at

    :unavailable
  end

  def availability_message(at: Time.current)
    failure = availability_failure(at:)
    AVAILABILITY_MESSAGES.fetch(failure) if failure
  end

  private

  def remember_source_file_blob
    @destroyed_source_file_blob = source_file.blob if source_file.attached?
  end

  def purge_destroyed_source_file_blob
    ActiveStorageMaintenance::Purge.call(blob: @destroyed_source_file_blob) if @destroyed_source_file_blob
  end
end
