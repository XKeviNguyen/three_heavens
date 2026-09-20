require "test_helper"
require "json"
require "open3"
require "rbconfig"

class PreflightExecutableTest < ActiveSupport::TestCase
  test "boots through Bundler before emitting JSON" do
    environment = {
      "RAILS_ENV" => "test",
      "APP_HOST" => nil,
      "RAILS_MASTER_KEY" => nil,
      "DATABASE_URL" => nil,
      "CACHE_DATABASE_URL" => nil,
      "QUEUE_DATABASE_URL" => nil,
      "CABLE_DATABASE_URL" => nil,
      "OPENROUTER_API_KEY" => "synthetic-no-provider-key",
      "LOCKED_JSON_VERSION" => Gem.loaded_specs.fetch("json").version.to_s
    }
    boot_guard = <<~'RUBY'
      executable = ARGV.shift
      module Kernel
        alias_method :require_without_preflight_boot_guard, :require

        def require(feature)
          if feature == "json" && Gem.loaded_specs["json"]&.version.to_s != ENV.fetch("LOCKED_JSON_VERSION")
            raise Gem::LoadError, "preflight required json before Bundler activated locked json"
          end

          require_without_preflight_boot_guard(feature)
        end
      end
      load executable
    RUBY

    stdout, stderr, status = Bundler.with_unbundled_env do
      Open3.capture3(
        environment,
        RbConfig.ruby,
        "-e",
        boot_guard,
        Rails.root.join("bin/ops/preflight").to_s,
        "--json",
        chdir: Rails.root.to_s
      )
    end

    output = stdout + stderr
    refute_match(/Gem::LoadError|already activated json|Gemfile requires json/i, output)

    result_line = stdout.lines.reverse.find { |line| line.lstrip.start_with?("{") }
    assert result_line, "preflight executable did not emit JSON: #{stderr.lines.last}"
    result = JSON.parse(result_line)

    assert_includes %w[healthy unavailable], result.fetch("status")
    assert result.fetch("checks").any? { |check| check.fetch("name") == "required_environment" }
    assert_equal(result.fetch("status") == "healthy", status.success?)
  end
end
