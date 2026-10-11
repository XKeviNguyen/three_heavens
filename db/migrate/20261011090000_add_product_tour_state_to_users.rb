# Durable onboarding state for the product tour: the tour version an account
# has resolved and how (completed it, dismissed it, or already existed when
# the tour shipped). NULL means the account has never resolved a tour and is
# offered one.
#
# Accounts that exist now are backfilled as 'preexisting' so the release never
# surprises established users with onboarding; an absent value is not taken as
# proof that an account is new. Accounts created afterwards, including by an
# old container during the deploy, start NULL and are offered the tour.
#
# users is small (one row per account), so the backfill and the validated
# CHECK constraint are cheap; lock_timeout keeps the brief ACCESS EXCLUSIVE
# lock from queueing behind long transactions.
class AddProductTourStateToUsers < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '1s'"
    add_column :users, :product_tour_version, :integer
    add_column :users, :product_tour_outcome, :string
    execute "UPDATE users SET product_tour_version = 1, product_tour_outcome = 'preexisting'"
    add_check_constraint :users,
      "(product_tour_version IS NULL AND product_tour_outcome IS NULL) OR " \
      "(product_tour_version IS NOT NULL AND product_tour_version > 0 AND product_tour_outcome IS NOT NULL AND " \
      "(product_tour_outcome = 'completed' OR product_tour_outcome = 'dismissed' OR product_tour_outcome = 'preexisting'))",
      name: "users_product_tour_check"
  end

  def down
    remove_check_constraint :users, name: "users_product_tour_check"
    remove_column :users, :product_tour_outcome
    remove_column :users, :product_tour_version
  end
end
