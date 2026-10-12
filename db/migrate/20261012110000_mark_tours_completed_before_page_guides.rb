# Welcome tours completed before page guides existed keep the switch off, the
# default for every existing account (see ProductTour.page_guides_enabled?).
# Marking them here separates them from tours the previous release completes
# after this migration, while it still serves during the deploy: those count
# as turning page guides on, like a completion recorded by the new code.
class MarkToursCompletedBeforePageGuides < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE users SET product_tour_guides_revision = 1
      WHERE product_tour_outcome = 'completed' AND product_tour_guides_revision = 0
    SQL
  end

  # Data only: the marks are harmless with the column, and dropped with it.
  def down; end
end
