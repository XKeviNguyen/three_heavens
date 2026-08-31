require "test_helper"

class DatabaseSchemaFormatTest < ActiveSupport::TestCase
  test "uses SQL only for primary databases" do
    configurations = ActiveRecord::Base.configurations

    assert_equal :sql, configurations.configs_for(env_name: "development", name: "primary").schema_format
    assert_equal :sql, configurations.configs_for(env_name: "test", name: "primary").schema_format
    assert_equal :sql, configurations.configs_for(env_name: "production", name: "primary").schema_format
    %w[cache queue cable].each do |name|
      assert_equal :ruby, configurations.configs_for(env_name: "production", name: name).schema_format
    end
  end
end
