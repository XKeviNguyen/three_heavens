class AccountMailerPreview < ActionMailer::Preview
  def confirm_email
    user = User.where(email_verified_at: nil).order(:id).first
    raise ArgumentError, "Create an unverified development account to preview confirmation mail" unless user

    AccountMailer.confirm_email(user)
  end
end
