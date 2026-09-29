class AppearancesController < ApplicationController
  skip_before_action :require_authentication
  # The preference lives on the user or in its own cookie. Saves often finish
  # in the background, so a session written here could overwrite a newer one.
  before_action { request.session_options[:skip] = true }

  def update
    appearance = params[:appearance].to_s
    raise ActionController::BadRequest unless User::APPEARANCES.include?(appearance)

    if current_user
      current_user.update!(appearance: appearance)
    else
      cookies[:ui_appearance] = {
        value: appearance, expires: 1.year.from_now, same_site: :lax, httponly: true, secure: Rails.env.production?
      }
    end

    respond_to do |format|
      format.json { head :no_content }
      format.html { redirect_back_to_same_origin }
    end
  end
end
