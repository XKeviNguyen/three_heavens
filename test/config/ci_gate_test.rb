require "test_helper"

# bin/ci (config/ci.rb) is the local gate and GitHub Actions runs the same
# checks split across jobs. A local check that no CI job runs, as happened
# with git diff --check, fails here. (CI also has setup steps with no local
# equivalent, so the reverse is not checked.)
class CiGateTest < ActiveSupport::TestCase
  # CI prepares its database from db/structure.sql and its tests fail on a
  # pending migration, so these database checks are only useful locally.
  LOCAL_ONLY = [ "bin/rails db:migrate:status", "bin/rails runner 'ActiveRecord::Migration.check_all_pending!'" ].freeze

  test "local and hosted gates have explicit matching test concurrency" do
    source = Rails.root.join("config/ci.rb").read
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/ci.yml").read)
    assert_includes source, 'ENV["PARALLEL_WORKERS"] ||= "4"'
    %w[test system-test].each do |job|
      assert_equal 4, workflow.fetch("jobs").fetch(job).fetch("env").fetch("PARALLEL_WORKERS")
    end
  end

  test "every local gate check runs in GitHub Actions" do
    source = Rails.root.join("config/ci.rb").read
    local = source.scan(/^\s*step "[^"]+", "([^"]+)"/).flatten
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/ci.yml").read)
    runs = workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps").filter_map { |step| step["run"] } }

    assert_equal source.scan(/^\s*step /).size, local.size, "every step in config/ci.rb is parsed"
    (local - LOCAL_ONLY).each do |command|
      covered = runs.any? do |run|
        if command.start_with?("bin/rails ")
          run.start_with?("bin/rails ") && (command.split.drop(1) - run.split.drop(1)).empty?
        else
          run.start_with?(command)
        end
      end
      assert covered, "#{command} is in config/ci.rb but no CI job runs it"
    end
  end
end
