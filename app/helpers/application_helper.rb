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

  def safe_provider_error(_message)
    # Historical rows may contain provider bodies from before safe error storage.
    "AI work failed. Review the error code before retrying explicitly."
  end

  def safe_provider_error_code(code)
    Ai::RunResult.safe_error_code(code)
  end

  def analytics_number(value, precision: 2)
    return "N/A" if value.nil?

    number_with_precision(value, precision: precision, strip_insignificant_zeros: true)
  end

  def analytics_percent(value)
    return "N/A" if value.nil?

    "#{analytics_number(value * 100, precision: 1)}%"
  end

  def analytics_money(value)
    return "N/A" if value.nil?

    number_to_currency(value, unit: "$", precision: 10, strip_insignificant_zeros: true)
  end

  def analytics_duration(seconds)
    return "N/A" if seconds.nil?

    if seconds < 1
      "#{analytics_number(seconds * 1_000, precision: 0)} ms"
    else
      "#{analytics_number(seconds, precision: 2)} s"
    end
  end
end
