require "test_helper"

class PumaConfigurationTest < ActiveSupport::TestCase
  test "Solid Queue in Puma is enabled only when explicitly true" do
    assert_equal [ :tmp_restart ], plugins_for(nil)
    assert_equal [ :tmp_restart ], plugins_for("false")
    assert_equal [ :tmp_restart, :solid_queue ], plugins_for("true")
  end

  test "Puma stops any request body above the largest the application accepts" do
    assert_equal RequestBodyLimit::MAX_BYTES, probe_configuration.content_length_limit
  end

  private

  def plugins_for(solid_queue_in_puma)
    original_value = ENV.delete("SOLID_QUEUE_IN_PUMA")
    ENV["SOLID_QUEUE_IN_PUMA"] = solid_queue_in_puma if solid_queue_in_puma

    probe_configuration.plugins
  ensure
    ENV.delete("SOLID_QUEUE_IN_PUMA")
    ENV["SOLID_QUEUE_IN_PUMA"] = original_value if original_value
  end

  def probe_configuration
    puma = PumaConfigurationProbe.new
    path = Rails.root.join("config/puma.rb").to_s
    puma.instance_eval(File.read(path), path)
    puma
  end

  class PumaConfigurationProbe
    attr_reader :plugins, :content_length_limit

    def initialize
      @plugins = []
    end

    def threads(*) = nil
    def port(*) = nil
    def pidfile(*) = nil

    def http_content_length_limit(limit)
      @content_length_limit = limit
    end

    def plugin(name)
      @plugins << name
    end
  end
end
