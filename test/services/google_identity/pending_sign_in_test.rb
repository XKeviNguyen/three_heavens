require "test_helper"

module GoogleIdentity
  class PendingSignInTest < ActiveSupport::TestCase
    test "an expired pending sign-in is refused even if the browser still sends it" do
      cookies = ActionDispatch::Request.new(Rails.application.env_config.dup).cookie_jar
      ceremony = Ceremony.resolve(Ceremony.issue(intent: "sign_in", locale: "en", appearance: "system", return_path: "/projects"))
      PendingSignIn.store(cookies, user: users(:normal), ceremony: ceremony)
      stored = cookies[PendingSignIn::COOKIE]

      travel(PendingSignIn::TTL + 1.second) do
        cookies[PendingSignIn::COOKIE] = stored
        assert_nil PendingSignIn.take(cookies)
      end

      cookies[PendingSignIn::COOKIE] = stored
      pending = PendingSignIn.take(cookies)
      assert_equal [ users(:normal).id, "/projects" ], [ pending.user_id, pending.return_path ]
    end
  end
end
