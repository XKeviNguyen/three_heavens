# One signed-in browser. The encrypted session cookie carries only this row's
# id, so signing out deletes the row and any copy of that cookie stops
# authenticating, while the account's other browsers keep their own rows.
# A row authenticates for LIFETIME after sign-in at most; expired rows are
# purged by SessionCleanupJob.
class Session < ApplicationRecord
  LIFETIME = 30.days

  belongs_to :user

  scope :unexpired, -> { where(created_at: LIFETIME.ago..) }
  scope :expired, -> { where(created_at: ...LIFETIME.ago) }
end
