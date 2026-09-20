class SessionsController < ApplicationController
  ALLOWED_SESSION_ATTRIBUTES = %w[email password].freeze
  INVALID_CREDENTIALS_MESSAGE = "The email or password is incorrect."
  LOGIN_RATE_LIMIT = 10
  LOGIN_RATE_LIMIT_WINDOW = 3.minutes

  skip_before_action :require_authentication, only: %i[new create]
  rate_limit to: LOGIN_RATE_LIMIT,
             within: LOGIN_RATE_LIMIT_WINDOW,
             with: :render_rate_limited,
             only: :create

  def new
    @email = ""
    redirect_to root_path if authenticated?
  end

  def create
    credentials = session_params
    @email = redisplayable_email(credentials[:email])

    unless credentials_within_size_limits?(credentials)
      return render_invalid_credentials
    end

    user = User.authenticate_by_email(
      email: credentials[:email],
      password: credentials[:password]
    )

    if user
      destination = start_authenticated_session!(user)
      redirect_to destination.presence || root_path, notice: "Signed in successfully."
    else
      render_invalid_credentials
    end
  rescue ActionController::ParameterMissing, ActionController::BadRequest
    @email = ""
    render_invalid_credentials(status: :bad_request)
  end

  def destroy
    end_authenticated_session!
    redirect_to login_path, notice: "Signed out successfully."
  end

  private

  def session_params
    submitted = params.require(:session)
    unless submitted.is_a?(ActionController::Parameters)
      raise ActionController::BadRequest, "session must be a parameter object"
    end

    unexpected_attributes = submitted.keys - ALLOWED_SESSION_ATTRIBUTES
    if unexpected_attributes.any?
      raise ActionController::BadRequest, "Unsupported session attributes"
    end

    ALLOWED_SESSION_ATTRIBUTES.each do |attribute|
      value = submitted[attribute]
      unless value.nil? || value.is_a?(String)
        raise ActionController::BadRequest, "#{attribute} must be a scalar value"
      end
    end

    submitted.permit(*ALLOWED_SESSION_ATTRIBUTES)
  end

  def credentials_within_size_limits?(credentials)
    credentials[:email].to_s.length <= User::MAXIMUM_EMAIL_LENGTH &&
      credentials[:password].to_s.length <= User::MAXIMUM_PASSWORD_LENGTH
  end

  def redisplayable_email(email)
    email if email && email.length <= User::MAXIMUM_EMAIL_LENGTH
  end

  def render_invalid_credentials(status: :unprocessable_content)
    flash.now[:alert] = INVALID_CREDENTIALS_MESSAGE
    render :new, status: status
  end

  def render_rate_limited
    response.set_header("Retry-After", LOGIN_RATE_LIMIT_WINDOW.to_i.to_s)
    @email = ""
    flash.now[:alert] = "Too many sign-in attempts. Wait three minutes, then try again."
    render :new, status: :too_many_requests
  end
end
