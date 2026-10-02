# One signed-in browser. The encrypted session cookie carries only this row's
# id, so signing out deletes the row and any copy of that cookie stops
# authenticating, while the account's other browsers keep their own rows.
class Session < ApplicationRecord
  belongs_to :user
end
