namespace :javascript do
  desc "Build the React islands bundle into app/assets/builds (requires npm ci)"
  task :build do
    abort "node_modules is missing. Run npm ci first." unless Rails.root.join("node_modules").directory?

    system("npm", "run", "build", chdir: Rails.root.to_s) || abort("npm run build failed")
  end
end

# Like tailwindcss-rails does for CSS: test runs need the bundle that the
# Dockerfile builds in its Node stage for production.
Rake::Task["test:prepare"].enhance([ "javascript:build" ]) if Rake::Task.task_defined?("test:prepare")
