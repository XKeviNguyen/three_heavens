require "test_helper"

# bin/ci (config/ci.rb) is the local gate and GitHub Actions runs the same
# checks split across jobs. A check added to one but not the other, as
# happened with git diff --check, fails here.
class CiGateTest < ActiveSupport::TestCase
  # CI prepares its database from db/structure.sql and fails on a pending
  # migration, so the migration status listing is only useful locally.
  LOCAL_ONLY = [ "bin/rails db:migrate:status" ].freeze

  test "every local gate check runs in GitHub Actions" do
    local = Rails.root.join("config/ci.rb").read.scan(/^\s*step "[^"]+", "([^"]+)"/).flatten
    workflow = YAML.safe_load(Rails.root.join(".github/workflows/ci.yml").read)
    runs = workflow.fetch("jobs").values.flat_map { |job| job.fetch("steps").filter_map { |step| step["run"] } }

    assert_operator local.size, :>=, 9
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
