require "test_helper"

class AccountMailerTest < ActionMailer::TestCase
  test "confirmation subject and body follow each saved locale" do
    expectations = {
      "en" => [ "Confirm your Three Heavens email", "This link expires after 24 hours." ],
      "vi" => [ "Xác nhận email", "24 giờ" ],
      "ja" => [ "メールアドレス", "24時間" ]
    }
    expectations.each do |locale, (subject, expiry)|
      user = User.create!(email: "mail-#{locale}@example.test", password: "a long secure password",
                          locale: locale, confirmation_sent_at: Time.current)
      message = AccountMailer.confirm_email(user)
      assert_includes message.subject, subject
      assert_includes message.text_part.body.decoded, expiry
      assert_includes message.html_part.body.decoded, "example.com"
    end
  end

  test "confirmation mail uses saved locale and configured host" do
    user = User.create!(email: "mail-preview@example.test", password: "a long secure password",
                        locale: "ja", confirmation_sent_at: Time.current)
    message = AccountMailer.confirm_email(user)
    assert_includes message.subject, "メールアドレス"
    assert_includes message.text_part.body.decoded, "example.com"
    assert_includes message.text_part.body.decoded, "24時間"
    assert_not_includes message.html_part.body.decoded, "OPENROUTER_API_KEY"
  end
end
