module Settings
  class OperationsController < ApplicationController
    before_action :require_admin

    def show
      @health = Operations::AiWorkflowHealth.call
      @system_health = Operations::SystemHealth.call
      @release_sha = Operations::ReleaseIdentity.call
    end

    def reconcile_stale
      result = Ai::StaleExecutionReconciler.call
      redirect_to settings_operations_path,
                  notice: "Reconciled #{result.total} stale AI run(s). No provider work was started."
    end
  end
end
