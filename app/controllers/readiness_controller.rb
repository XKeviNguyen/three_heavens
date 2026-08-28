class ReadinessController < ActionController::Base
  class_attribute :database_check,
                  instance_writer: false,
                  default: -> { ActiveRecord::Base.connection.select_value("SELECT 1") }

  def show
    database_check.call
    response.headers["Cache-Control"] = "no-store"
    render plain: "ready\n", status: :ok
  rescue ActiveRecord::ActiveRecordError
    response.headers["Cache-Control"] = "no-store"
    render plain: "unavailable\n", status: :service_unavailable
  end
end
