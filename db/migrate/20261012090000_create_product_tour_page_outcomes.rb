# Per-account progress for contextual page guides (ProductTour::PAGE_TOURS).
# Additive and compatible with the deployed release, which ignores both:
# - users.product_tour_page_guides: whether page guides open automatically.
#   Off for every existing account; it is turned on only when a newly offered
#   global tour is completed (ProductTour.record_outcome!).
# - one row per account, page context and guide version, written once: the
#   unique index makes a repeated or concurrent write a no-op.
class CreateProductTourPageOutcomes < ActiveRecord::Migration[8.1]
  def up
    execute "SET LOCAL lock_timeout = '1s'"
    # A constant default needs no table rewrite (PostgreSQL 11+).
    add_column :users, :product_tour_page_guides, :boolean, null: false, default: false

    create_table :product_tour_page_outcomes do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :tour_key, null: false
      t.integer :version, null: false
      t.string :outcome, null: false
      t.datetime :created_at, null: false
    end
    add_index :product_tour_page_outcomes, %i[user_id tour_key version], unique: true,
      name: "index_product_tour_page_outcomes_once"
    add_check_constraint :product_tour_page_outcomes, "outcome = 'completed' OR outcome = 'dismissed'",
      name: "product_tour_page_outcomes_outcome_check"
    add_check_constraint :product_tour_page_outcomes, "version > 0",
      name: "product_tour_page_outcomes_version_check"
    add_check_constraint :product_tour_page_outcomes,
      "char_length(tour_key) <= 64 AND tour_key ~ '^[a-z_]+:(list|form|detail)$'",
      name: "product_tour_page_outcomes_key_check"
  end

  def down
    drop_table :product_tour_page_outcomes
    remove_column :users, :product_tour_page_guides
  end
end
