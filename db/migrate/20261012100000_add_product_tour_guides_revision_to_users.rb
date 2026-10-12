# Orders the page-guides switch by commit, not by clock: every write to
# users.product_tour_page_guides increments this counter in the same UPDATE,
# under the row lock, so a browser can tell which of two values is newer.
# Additive and compatible with the deployed release, which ignores it.
class AddProductTourGuidesRevisionToUsers < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '1s'"
    # A constant default needs no table rewrite (PostgreSQL 11+).
    add_column :users, :product_tour_guides_revision, :bigint, null: false, default: 0
    add_check_constraint :users, "product_tour_guides_revision >= 0", name: "users_product_tour_guides_revision_check"
  end

  def down
    remove_column :users, :product_tour_guides_revision
  end
end
