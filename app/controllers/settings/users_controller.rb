module Settings
  class UsersController < ApplicationController
    before_action :require_admin

    def index
      @users = paginate(User.order(:id))
    end

    def grant_managed_ai_access
      change_access(true)
    end

    def revoke_managed_ai_access
      change_access(false)
    end

    private

    def change_access(allowed)
      user = User.find(params[:id])
      user.with_lock { user.update!(managed_ai_access: allowed) }
      Operations::EventLogger.emit("managed_ai_access_changed", user_id: user.id,
                                   actor_id: current_user.id, status: allowed ? "granted" : "revoked")
      redirect_to settings_users_path, notice: t(allowed ? "admin_users.granted" : "admin_users.revoked")
    end
  end
end
