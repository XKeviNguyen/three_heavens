module Settings
  class GoogleIdentitiesController < ApplicationController
    def create
      pending = GoogleIdentity::PendingLink.fetch(cookies)
      GoogleIdentity::PendingLink.clear(cookies)
      status = GoogleIdentity::Link.call(user: current_user, pending: pending)

      if status.in?(%i[connected already_connected])
        redirect_to settings_account_path, notice: t("account.google.connected"), status: :see_other
      else
        redirect_to settings_account_path, alert: t("account.google.errors.#{status}"), status: :see_other
      end
    end

    def cancel_pending
      GoogleIdentity::PendingLink.clear(cookies)
      redirect_to settings_account_path, status: :see_other
    end

    def destroy
      case GoogleIdentity::Disconnect.call(user: current_user)
      when :disconnected
        redirect_to settings_account_path, notice: t("account.google.disconnected"), status: :see_other
      when :only_sign_in_method
        redirect_to settings_account_path, alert: t("account.google.errors.only_sign_in_method"), status: :see_other
      else
        redirect_to settings_account_path, status: :see_other
      end
    end
  end
end
