namespace :pipelines do
  desc "Reconcile a bounded batch of authorized automatic pipelines"
  task reconcile: :environment do
    result = Pipelines::Reconcile.call
    puts "Examined #{result.examined_count} authorized pipeline(s); changed #{result.advanced_count}."
  end
end
