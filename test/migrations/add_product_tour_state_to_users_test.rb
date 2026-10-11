require "test_helper"
require Rails.root.join("db/migrate/20261011090000_add_product_tour_state_to_users")

class AddProductTourStateToUsersTest < ActiveSupport::TestCase
  teardown { User.reset_column_information }

  test "accounts that exist at deployment are never offered onboarding; later sign-ups are" do
    migration = AddProductTourStateToUsers.new
    migration.verbose = false
    migration.down
    User.reset_column_information
    existing = User.create!(email: "existing@example.test", password: "existing account password", email_verified_at: Time.current)

    migration.up
    User.reset_column_information

    assert_equal [ [ 1, "preexisting" ] ], User.distinct.pluck(:product_tour_version, :product_tour_outcome)
    assert_not ProductTour.offered?(existing.reload)

    newcomer = User.create!(email: "newcomer@example.test", password: "newcomer account password", email_verified_at: Time.current)
    assert_nil newcomer.reload.product_tour_version
    assert ProductTour.offered?(newcomer)
  end
end
