require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "normalizes email and enforces case-insensitive uniqueness" do
    user = User.create!(
      email: "  New.Account@Example.TEST ",
      password: "a sufficiently secure password",
      role: :user
    )
    duplicate = User.new(
      email: "NEW.ACCOUNT@example.test",
      password: "another sufficiently secure password"
    )

    assert_equal "new.account@example.test", user.email
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:email], "has already been taken"
  end

  test "requires a production-length password" do
    user = User.new(email: "short-password@example.test", password: "too-short")

    assert_not user.valid?
    assert user.errors[:password].any?
  end

  test "disabled accounts cannot authenticate" do
    user = users(:normal)
    user.update!(status: :disabled)

    assert_nil User.authenticate_by_email(
      email: user.email,
      password: "correct horse battery staple"
    )
  end

  test "user deletion is conservatively restricted when projects exist" do
    user = users(:normal)

    assert_not user.destroy
    assert User.exists?(user.id)
    assert user.errors[:base].any?
  end
end
