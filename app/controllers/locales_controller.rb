class LocalesController < ApplicationController
  skip_before_action :require_authentication

  def update
    locale = params[:locale_code].to_s
    raise ActionController::BadRequest unless User::SUPPORTED_LOCALES.include?(locale)

    if current_user
      ui_preferences.choose_as_user(current_user, locale: locale)
    else
      ui_preferences.choose_as_guest(locale: locale)
    end
    redirect_back_to_same_origin
  end
end
