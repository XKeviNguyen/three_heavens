module ApplicationHelper
  def status_badge_classes(status)
    case status.to_s
    when "completed"
      "bg-emerald-100 text-emerald-800"
    when "failed"
      "bg-red-100 text-red-800"
    when "running"
      "bg-blue-100 text-blue-800"
    else
      "bg-amber-100 text-amber-800"
    end
  end

  def safe_provider_error(message)
    Ai::ErrorSanitizer.call(message)
  end
end
