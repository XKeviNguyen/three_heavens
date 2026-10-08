require "test_helper"
require "puma"
require "puma/configuration"

class PumaConfigurationTest < ActiveSupport::TestCase
  test "Solid Queue in Puma is enabled only when explicitly true" do
    assert_equal [ :tmp_restart ], plugins_for(nil)
    assert_equal [ :tmp_restart ], plugins_for("false")
    assert_equal [ :tmp_restart, :solid_queue ], plugins_for("true")
  end

  test "Puma stops any request body above the largest the application accepts" do
    assert_equal RequestBodyLimit::MAX_BYTES, probe_configuration.content_length_limit
  end

  # PDF extraction admits one worker per Puma process, sized for the whole
  # container, so more processes would multiply its memory bound.
  test "Puma refuses to start more than one process per container" do
    [ nil, "", "0", "1" ].each do |value|
      assert_nothing_raised { with_web_concurrency(value) { probe_configuration } }
    end
    [ "2", "auto" ].each do |value|
      error = assert_raises(RuntimeError, value) { with_web_concurrency(value) { probe_configuration } }
      assert_match(/WEB_CONCURRENCY must be 1/, error.message)
    end
  end

  test "one Puma process serves the container whatever WEB_CONCURRENCY allows" do
    [ nil, "", "0", "1" ].each do |value|
      with_web_concurrency(value) do
        configuration = Puma::Configuration.new({ config_files: [ Rails.root.join("config/puma.rb").to_s ] }, {}, ENV)
        configuration.load
        configuration.clamp

        assert_equal 0, configuration.options[:workers], "WEB_CONCURRENCY=#{value.inspect} must run Puma in single mode"
      end
    end
  end

  private

  def with_web_concurrency(value)
    original_value = ENV.delete("WEB_CONCURRENCY")
    ENV["WEB_CONCURRENCY"] = value if value
    yield
  ensure
    ENV.delete("WEB_CONCURRENCY")
    ENV["WEB_CONCURRENCY"] = original_value if original_value
  end

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
    def workers(*) = nil
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
