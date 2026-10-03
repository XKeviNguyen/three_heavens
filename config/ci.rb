# The complete local quality gate (AGENTS.md). Run it with bin/ci.
# .github/workflows/ci.yml runs these same checks, split across its jobs;
# test/config/ci_gate_test.rb fails if the two drift apart.
CI.run do
  step "Style: Ruby", "bin/rubocop"
  step "Style: Whitespace", "git diff --check $(git hash-object -t tree /dev/null)"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --no-pager"

  step "Code: Autoloading", "bin/rails zeitwerk:check"
  step "Database: Migrations", "bin/rails db:migrate:status"
  step "Tests: Rails", "bin/rails test"
  step "Tests: System", "bin/rails test:system"
end
