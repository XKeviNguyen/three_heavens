namespace :source_imports do
  desc "Purge one bounded batch of expired, abandoned source imports"
  task cleanup: :environment do
    result = SourceImports::Cleanup.call
    puts "Purged #{result.purged_count} expired source import(s)."
  end
end
