require "test_helper"
require "yaml"

class ApplicationLocaleTest < ActiveSupport::TestCase
  test "application locale key sets match across English Vietnamese and Japanese" do
    %w[public workspace model_browser validation terminology_sheet projects domain_labels history glossaries methodology workflows_ui references admin_models operations_ui datetime results_ui pipelines_ui final_ui benchmarks_ui flash_ui retry_feedback shared workspace_extras].each do |group|
      keys = %w[en vi ja].to_h do |locale|
        path = Rails.root.join("config/locales/#{group}.#{locale}.yml")
        [ locale, flatten(YAML.load_file(path).fetch(locale)) ]
      end
      assert_equal keys.fetch("en"), keys.fetch("vi"), "#{group}: Vietnamese keys differ"
      assert_equal keys.fetch("en"), keys.fetch("ja"), "#{group}: Japanese keys differ"
    end
  end

  private

  def flatten(hash, prefix = "")
    hash.flat_map do |key, value|
      path = [ prefix, key ].reject(&:empty?).join(".")
      value.is_a?(Hash) ? flatten(value, path) : [ path ]
    end.sort
  end
end
