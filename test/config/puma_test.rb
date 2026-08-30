require "test_helper"

class PumaConfigurationTest < ActiveSupport::TestCase
  test "Solid Queue in Puma is enabled only when explicitly true" do
    assert_equal [ :tmp_restart ], plugins_for(nil)
    assert_equal [ :tmp_restart ], plugins_for("false")
    assert_equal [ :tmp_restart, :solid_queue ], plugins_for("true")
  end

  private

  def plugins_for(solid_queue_in_puma)
    original_value = ENV.delete("SOLID_QUEUE_IN_PUMA")
    ENV["SOLID_QUEUE_IN_PUMA"] = solid_queue_in_puma if solid_queue_in_puma

    puma = PumaConfigurationProbe.new
    puma.instance_eval(Rails.root.join("config/puma.rb").read, "config/puma.rb")
    puma.plugins
  ensure
    ENV.delete("SOLID_QUEUE_IN_PUMA")
    ENV["SOLID_QUEUE_IN_PUMA"] = original_value if original_value
  end

  class PumaConfigurationProbe
    attr_reader :plugins

    def initialize
      @plugins = []
    end

    def threads(*) = nil
    def port(*) = nil
    def pidfile(*) = nil

    def plugin(name)
      @plugins << name
    end
  end
end
