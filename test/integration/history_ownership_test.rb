require "test_helper"
require_relative "../support/analytics_test_helper"

class HistoryOwnershipTest < ActionDispatch::IntegrationTest
  include AnalyticsTestHelper

  test "history exposes only the signed-in user's experiment metadata" do
    model = create_analytics_model(name: "History scope model")
    own_experiment, = create_analytics_experiment(
      name: "Visible owned experiment",
      models: [ model ],
      user: users(:normal)
    )
    foreign_experiment, = create_analytics_experiment(
      name: "Private foreign experiment",
      models: [ model ],
      user: users(:other)
    )
    sign_in_as users(:normal)

    get history_path

    assert_response :success
    assert_includes response.body, own_experiment.name
    assert_not_includes response.body, foreign_experiment.name
    assert_select "a[href='#{experiment_path(own_experiment)}']"
    assert_select "a[href='#{experiment_path(foreign_experiment)}']", count: 0
  end

  test "benchmark pages use owner scope for users and global aggregate scope for admins" do
    model = create_analytics_model(name: "Role-scoped benchmark model")
    create_analytics_experiment(
      name: "Normal user's benchmark identity",
      models: [ model ],
      user: users(:normal)
    )
    create_analytics_experiment(
      name: "Other user's private benchmark identity",
      models: [ model ],
      user: users(:other)
    )

    sign_in_as users(:normal)
    get benchmarks_path
    assert_select "article[data-model-id='#{model.id}']", text: /Completed translations\s*1/m

    sign_out
    sign_in_as users(:admin)
    get benchmarks_path
    assert_select "article[data-model-id='#{model.id}']", text: /Completed translations\s*2/m

    get benchmark_model_path(model)
    assert_not_includes response.body, "Normal user's benchmark identity"
    assert_not_includes response.body, "Other user's private benchmark identity"
  end
end
