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

  # Starts a session only while the account is active, else returns nil.
  # Disabling an account updates its row and deletes its sessions in one
  # transaction. Locking that row first orders the two, so a sign-in racing a
  # disable cannot write a session that re-enabling the account would revive.
  def self.start(user)
    transaction do
      create!(user:) if User.active.where(id: user.id).lock("FOR SHARE").exists?
    end
  end
end
