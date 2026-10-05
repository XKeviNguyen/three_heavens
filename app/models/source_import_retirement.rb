class SourceImportRetirement < ApplicationRecord
  belongs_to :user
  attr_readonly :user_id, :request_key

  # Deleting staged content must not delete its delivery identity. Keep only
  # the owner/key tombstone, never source bytes, text, filenames, or outcomes.
  validates :request_key, format: { with: SourceImports::Limits::REQUEST_KEY_FORMAT }
end
