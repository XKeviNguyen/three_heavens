class EmailConfirmationsController < ApplicationController
  layout "public"
  skip_before_action :require_authentication
  before_action :private_confirmation_response

  def show
    @token = params[:token].to_s
    @user = User.find_by_token_for(:email_confirmation, @token)
  end

  def create
    token = params.require(:token).to_s
    user = User.find_by_token_for(:email_confirmation, token)
    if user && !user.email_verified?
      user.update!(email_verified_at: Time.current)
      redirect_to login_path, notice: t("email_confirmation.confirmed")
    else
      redirect_to new_confirmation_resend_path, alert: t("email_confirmation.invalid")
    end
  rescue ActionController::ParameterMissing
    redirect_to new_confirmation_resend_path, alert: t("email_confirmation.invalid")
  end

  private

  def private_confirmation_response
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end
end
