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
    redirect_back_to_same_origin
  end
end
