# Orders the page-guides switch by commit, not by clock: every write to
# users.product_tour_page_guides increments this counter in the same UPDATE,
# under the row lock, so a browser can tell which of two values is newer.
# Additive and compatible with the deployed release, which ignores it.
#
# It also tells apart welcome tours the previous release completes during
# the deploy (revision 0: they turn page guides on, see
# ProductTour.page_guides_enabled?) from tours completed before it (marked 1
# here: they keep the switch off, the default for existing accounts). The mark
# is written in this migration's transaction, which holds the table lock taken
# by add_column, so a completion the old release writes meanwhile waits and
# commits after it, unmarked.
class AddProductTourGuidesRevisionToUsers < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '1s'"
    # A constant default needs no table rewrite (PostgreSQL 11+).
    add_column :users, :product_tour_guides_revision, :bigint, null: false, default: 0
    add_check_constraint :users, "product_tour_guides_revision >= 0", name: "users_product_tour_guides_revision_check"
    execute "UPDATE users SET product_tour_guides_revision = 1 WHERE product_tour_outcome = 'completed'"
  end

  def down
    remove_column :users, :product_tour_guides_revision
  end
end
