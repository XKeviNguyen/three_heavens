require "digest"

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "support/network_guard"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Terminal history is database-sealed. A few presentation/query tests need
    # intentionally malformed historical fixtures without weakening production.
    def mutate_historical_fixture(&block)
      ActiveRecord::Base.connection.disable_referential_integrity(&block)
    end
  end
end

module AuthenticationTestHelper
  def sign_in_as(user, password: nil)
    post session_path, params: {
      session: {
        email: user.email,
        password: password || password_for(user)
      }
    }, headers: login_rate_limit_headers
    follow_redirect! if response.redirect?
  end

  def sign_out
    delete session_path
  end

  # The account the integration session's cookie authenticates as, via its
  # server-side session row.
  def signed_in_user_id
    Session.find_by(id: session[:authentication_session_id])&.user_id
  end

  def issue_translation_workspace_token(user: users(:normal), at: Time.current)
    TranslationWorkspaceSubmission.issue_token(user: user, at: at)
  end

  # Looks up the launch row without creating it (claim! would create it).
  def translation_workspace_submission_for(token, user: users(:normal))
    user.translation_workspace_submissions.find_by!(token_digest: Digest::SHA256.hexdigest(token))
  end

  private

  def login_rate_limit_headers
    digest = Digest::SHA256.hexdigest("#{self.class.name}:#{name}")
    address_groups = digest.first(24).scan(/.{4}/)
    { "REMOTE_ADDR" => "2001:db8:#{address_groups.join(':')}" }
  end

  def password_for(user)
    {
      "user@example.test" => "correct horse battery staple",
      "other@example.test" => "other secure password value",
      "admin@example.test" => "admin secure password value"
    }.fetch(user.email)
  end
end

ActionDispatch::IntegrationTest.include(AuthenticationTestHelper)
# Each example starts with independent login throttle windows; the per-account
# budget would otherwise carry over between examples signing in as a fixture.
ActionDispatch::IntegrationTest.setup { ActionController::Base.cache_store.clear }
