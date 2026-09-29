module Settings
  class AccountsController < ApplicationController
    before_action { response.headers["Cache-Control"] = "no-store" }

    def show
      @google_identity = current_user.federated_identities.find_by(provider: GoogleIdentity::PROVIDER)
      @pending_link = GoogleIdentity::PendingLink.fetch(cookies)
      unless @pending_link&.for?(current_user)
        GoogleIdentity::PendingLink.clear(cookies) if @pending_link
        @pending_link = nil
      end
    end
  end
end
