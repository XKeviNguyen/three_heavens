class AppearancesController < ApplicationController
  skip_before_action :require_authentication
  # The preference lives on the user or in its own cookie. Saves often finish
  # in the background, so a session written here could overwrite a newer one.
  before_action { request.session_options[:skip] = true }

  def update
    appearance = params[:appearance].to_s
    raise ActionController::BadRequest unless User::APPEARANCES.include?(appearance)

    revision = params[:revision]
    unless revision.nil? || (revision.is_a?(String) && revision.match?(UiPreferences::APPEARANCE_REVISION_FORMAT))
      raise ActionController::BadRequest
    end

    if current_user
      ui_preferences.choose_as_user(current_user, appearance: appearance)
    else
      ui_preferences.choose_as_guest(appearance: appearance)
    end
    ui_preferences.record_appearance_revision(revision) if revision

    respond_to do |format|
      format.json { head :no_content }
      format.html { redirect_back_to_same_origin }
    end
  end
end
