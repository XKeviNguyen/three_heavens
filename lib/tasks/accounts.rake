namespace :accounts do
  desc "Create or update the admin account from environment variables"
  task bootstrap_admin: :environment do
    Accounts::BootstrapAdmin.call
    puts "Admin account bootstrapped successfully."
  rescue Accounts::BootstrapAdmin::ConfigurationError, ActiveRecord::RecordInvalid => error
    abort "Admin bootstrap failed: #{error.message}"
  end
end
