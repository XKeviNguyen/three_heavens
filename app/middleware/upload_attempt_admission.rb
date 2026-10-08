# CookieStore supplies identity without reading rack.input. This gate must run
# before MethodOverride, which parses POST multipart bodies even without _method.
class UploadAttemptAdmission
  BODY_METHODS = %w[POST PATCH PUT].freeze

  def initialize(app)
    @app = app
  end

  def call(environment)
    return @app.call(environment) unless upload_request?(environment)

    request = ActionDispatch::Request.new(environment)
    session_id = request.session[:authentication_session_id]
    user = if session_id.to_s.match?(/\A[1-9]\d*\z/)
      User.active.where.not(email_verified_at: nil).joins(:sessions).merge(Session.unexpired)
        .find_by(sessions: { id: session_id })
    end
    return rejection(401, "Sign in to upload files.", "authentication_required") unless user
    unless UploadBudget.admit_attempt(user:)
      return rejection(429, I18n.t("source_imports.errors.rate_limited", locale: user.locale), "rate_limited")
    end

    @app.call(environment)
  end

  private

  def upload_request?(environment)
    return false unless BODY_METHODS.include?(environment["REQUEST_METHOD"])

    path = environment["PATH_INFO"].to_s.squeeze("/").sub(%r{(?<=.)/\z}, "").sub(%r{\.[^./]*\z}, "")
    return true if path == "/source_imports"

    path.match?(%r{\A/translation_references(?:/[^/]+)?\z}) &&
      Rack::MediaType.type(environment["CONTENT_TYPE"]).to_s.start_with?("multipart/")
  end

  def rejection(status, message, code)
    headers = { "content-type" => "application/json", "cache-control" => "no-store" }
    headers["retry-after"] = SourceImports::Limits::UPLOAD_WINDOW.to_i.to_s if status == 429
    [ status, headers, [ JSON.generate(error: message, code:) ] ]
  end
end
