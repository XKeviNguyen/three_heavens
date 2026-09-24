class AccountMailer < ApplicationMailer
  def confirm_email(user)
    @user = user
    @confirmation_url = email_confirmation_url(token: user.generate_token_for(:email_confirmation))
    I18n.with_locale(user.locale) do
      mail(to: user.email, subject: I18n.t("email_confirmation.subject"))
    end
  end
end
