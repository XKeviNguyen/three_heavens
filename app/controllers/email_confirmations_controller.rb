class EmailConfirmationsController < ApplicationController
  layout "public"
  skip_before_action :require_authentication
  before_action :private_confirmation_response
  rate_limit to: 10, within: 15.minutes, by: :client_network, only: :create, with: :render_rate_limited

  def show
    @token = params[:token].to_s
    @user = User.find_by_token_for(:email_confirmation, @token)
  end

  # Confirming proves control of the mailbox; the password proves this is
  # the registration its owner made. Without it, whoever registered the
  # address first (Accounts::Registration) would keep a password the
  # mailbox owner never chose.
  def create
    @token = params.require(:token).to_s
    password = params[:password]
    @user = User.find_by_token_for(:email_confirmation, @token)
    return redirect_invalid unless @user

    outcome = @user.with_lock do
      # A resend or a new registration since the link was issued replaced it.
      next :invalid unless User.find_by_token_for(:email_confirmation, @token) == @user && !@user.email_verified?
      next :wrong_password unless password.is_a?(String) && @user.authenticate_password(password)

      @user.update!(email_verified_at: Time.current)
      :confirmed
    end

    case outcome
    when :confirmed then sign_in_confirmed
    when :wrong_password
      flash.now[:alert] = t("email_confirmation.password_incorrect")
      render :show, status: :unprocessable_content
    else redirect_invalid
    end
  rescue ActionController::ParameterMissing
    redirect_invalid
  end

  private

  def sign_in_confirmed
    destination = start_authenticated_session!(@user)
    return redirect_to(login_path, notice: t("email_confirmation.confirmed")) if destination == false

    redirect_to destination.presence || new_translation_workspace_path,
                notice: I18n.with_locale(@user.locale) { t("email_confirmation.confirmed") }
  end

  def render_rate_limited
    response.set_header("Retry-After", 15.minutes.to_i.to_s)
    @token = params[:token].to_s
    @user = User.find_by_token_for(:email_confirmation, @token)
    flash.now[:alert] = t("email_confirmation.rate_limited")
    render :show, status: :too_many_requests
  end

  def redirect_invalid
    redirect_to new_confirmation_resend_path, alert: t("email_confirmation.invalid")
  end

  def private_confirmation_response
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
  end
end
