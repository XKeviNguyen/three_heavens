class LocalesController < ApplicationController
  skip_before_action :require_authentication

  def update
    locale = params[:locale_code].to_s
    raise ActionController::BadRequest unless User::SUPPORTED_LOCALES.include?(locale)

    if current_user
      current_user.update!(locale: locale)
    else
      cookies[:ui_locale] = { value: locale, expires: 1.year.from_now, same_site: :lax, httponly: true }
    end
    destination = request.referer.to_s
    uri = URI.parse(destination)
    path = uri.host == request.host && uri.port == request.port ? uri.request_uri : root_path
    redirect_to path, allow_other_host: false
  rescue URI::InvalidURIError
    redirect_to root_path
  end
end
