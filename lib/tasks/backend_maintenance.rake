namespace :backend do
  desc "Preview or execute one bounded batch of stale unattached Active Storage blob cleanup"
  task cleanup_unattached_blobs: :environment do
    days = Integer(ENV.fetch("OLDER_THAN_DAYS", "7"), 10)
    raise ArgumentError, "OLDER_THAN_DAYS must be positive" unless days.positive?

    result = ActiveStorageMaintenance::Cleanup.call(
      cutoff: days.days.ago,
      batch_size: ENV.fetch("BATCH_SIZE", "100"),
      execute: ENV["EXECUTE"] == "1"
    )
    puts "Candidates: #{result.candidate_count}; purged: #{result.purged_count}; execute: #{ENV['EXECUTE'] == '1'}"
  end

  desc "Preview or execute bounded sanitization of legacy failed-run error messages"
  task remediate_legacy_errors: :environment do
    before = Time.iso8601(ENV.fetch("BEFORE"))
    result = Ai::LegacyErrorRemediation.call(
      before: before,
      batch_size: ENV.fetch("BATCH_SIZE", "100"),
      execute: ENV["EXECUTE"] == "1"
    )
    puts "Candidates: #{result.candidate_count}; remediated: #{result.remediated_count}; execute: #{ENV['EXECUTE'] == '1'}"
  end
end
