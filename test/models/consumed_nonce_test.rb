require "test_helper"

class ConsumedNonceTest < ActiveSupport::TestCase
  test "a value is consumed once per namespace and only its digest is stored" do
    expires_at = 10.minutes.from_now

    assert ConsumedNonce.consume("first", "value", expires_at:)
    assert_not ConsumedNonce.consume("first", "value", expires_at:)
    assert ConsumedNonce.consume("second", "value", expires_at:)
    assert_equal [ OpenSSL::Digest::SHA256.hexdigest("first:value") ], ConsumedNonce.where(digest: OpenSSL::Digest::SHA256.hexdigest("first:value")).pluck(:digest)
    assert_not ConsumedNonce.where("digest LIKE ?", "%value%").exists?
  end

  test "the database refuses anything but a digest" do
    assert_raises(ActiveRecord::StatementInvalid) do
      ConsumedNonce.insert({ digest: "plain value", expires_at: 1.minute.from_now, created_at: Time.current })
    end
  end

  test "cleanup removes only expired records, so a live value stays spent" do
    assert ConsumedNonce.consume("cleanup", "expired", expires_at: 1.minute.ago)
    assert ConsumedNonce.consume("cleanup", "live", expires_at: 1.minute.from_now)

    SessionCleanupJob.perform_now

    assert_not ConsumedNonce.consume("cleanup", "live", expires_at: 1.minute.from_now)
    assert_equal 1, ConsumedNonce.count
  end
end
