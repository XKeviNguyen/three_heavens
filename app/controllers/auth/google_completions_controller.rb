module Auth
  # Finishes a Google sign-in that the cross-site callback verified. This is a
  # top-level same-site navigation, so the browser's session cookie is present
  # and start_authenticated_session! ends the session it replaces.
  class GoogleCompletionsController < ApplicationController
    skip_before_action :require_authentication

    def show
      pending = GoogleIdentity::PendingSignIn.take(cookies)
      user = User.active.where.not(email_verified_at: nil).find_by(id: pending.user_id) if pending
      return reject unless user

      destination = start_authenticated_session!(user, preference_overrides: pending.preference_overrides)
      return reject if destination == false

      I18n.with_locale(user.locale) do
        redirect_to pending.return_path || destination.presence || new_translation_workspace_path,
                    notice: t("authentication.signed_in"), status: :see_other
      end
    end

    private

    # A visitor still signed in keeps that session; the login page would
    # forward them to Account as if linking had failed.
    def reject
      return redirect_to new_translation_workspace_path, alert: t("google_identity.messages.failed"), status: :see_other if authenticated?

      GoogleIdentity::Notice.store(cookies, "failed")
      redirect_to login_path, status: :see_other
    end
  end
end
