namespace :ai do
  desc "Mark stale running AI work failed and reconcile parent workflows"
  task reconcile_stale: :environment do
    result = Ai::StaleExecutionReconciler.call
    puts "Reconciled #{result.total} stale AI run(s)."
    result.failed_counts.each do |type, count|
      puts "#{type}: #{count} " \
           "(pending: #{result.pending_failed_counts.fetch(type)}, " \
           "running: #{result.running_failed_counts.fetch(type)})"
    end
  end
end
