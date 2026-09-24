class ConfirmationResendsController < ApplicationController
  layout "public"
  skip_before_action :require_authentication
  rate_limit to: 3, within: 1.hour, only: :create, with: :render_rate_limited

  def new
  end

  def create
    email = params[:email]
    raise ActionController::BadRequest unless email.is_a?(String) && email.length <= User::MAXIMUM_EMAIL_LENGTH
    user = User.active.find_by(email: User.normalize_value_for(:email, email))
    if user && !user.email_verified? && (user.confirmation_sent_at.nil? || user.confirmation_sent_at < 3.minutes.ago)
      user.update!(confirmation_sent_at: Time.current)
      AccountMailer.confirm_email(user).deliver_later
    end
    redirect_to new_confirmation_resend_path, notice: t("email_confirmation.resend_sent")
  rescue ActionController::BadRequest
    head :bad_request
  end

  private

  def render_rate_limited
    response.set_header("Retry-After", 1.hour.to_i.to_s)
    redirect_to new_confirmation_resend_path, notice: t("email_confirmation.resend_sent")
  end
end
