class RegistrationsController < ApplicationController
  layout "public"
  ALLOWED_ATTRIBUTES = %w[email password password_confirmation].freeze
  skip_before_action :require_authentication
  rate_limit to: 5, within: 1.hour, by: :client_network, only: :create, with: :render_rate_limited

  def new
    @user = User.new
  end

  def create
    submitted = params.require(:user)
    raise ActionController::BadRequest unless submitted.is_a?(ActionController::Parameters)
    raise ActionController::BadRequest if (submitted.keys - ALLOWED_ATTRIBUTES).any?

    attributes = submitted.permit(*ALLOWED_ATTRIBUTES)
    raise ActionController::BadRequest unless attributes.values.all? { |value| value.is_a?(String) }
    raise ActionController::BadRequest if attributes[:email].to_s.length > User::MAXIMUM_EMAIL_LENGTH
    raise ActionController::BadRequest if attributes[:password].to_s.length > User::MAXIMUM_PASSWORD_LENGTH
    raise ActionController::BadRequest if attributes[:password_confirmation].to_s.length > User::MAXIMUM_PASSWORD_LENGTH

    @user = User.new(email: attributes[:email], password: attributes[:password],
                     password_confirmation: attributes[:password_confirmation],
                     role: :user, status: :active, managed_ai_access: false, locale: I18n.locale.to_s)
    @user.confirmation_sent_at = Time.current
    if @user.save
      AccountMailer.confirm_email(@user).deliver_later
      redirect_to new_confirmation_resend_path, notice: t("registration.check_email")
    else
      @user.password = @user.password_confirmation = nil
      render :new, status: :unprocessable_content
    end
  rescue ActionController::ParameterMissing, ActionController::BadRequest
    head :bad_request
  end

  private

  def render_rate_limited
    response.set_header("Retry-After", 1.hour.to_i.to_s)
    @user = User.new
    flash.now[:alert] = t("registration.rate_limited")
    render :new, status: :too_many_requests
  end
end
