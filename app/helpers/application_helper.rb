module ApplicationHelper
  NAVIGATION_SECTIONS = {
    workspace: %w[translation_workspaces source_imports],
    projects: %w[projects documents experiments review_rounds judge_rounds final_translations pipeline_runs],
    history: %w[history],
    libraries: %w[workflow_profiles glossaries methodology_profiles translation_references],
    benchmarks: %w[benchmarks],
    administration: %w[settings/models settings/operations]
  }.freeze

  def status_badge_classes(status)
    case status.to_s
    when "completed", "finalized", "ready_for_editor", "active"
      "bg-emerald-100 text-emerald-800"
    when "failed", "blocked"
      "bg-red-100 text-red-800"
    when "running"
      "bg-blue-100 text-blue-800"
    when "stopped", "inactive", "archived"
      "bg-slate-200 text-slate-700"
    else
      "bg-amber-100 text-amber-800"
    end
  end

  def navigation_link(label, path, section:, compact: false, controllers: nil)
    active = Array(controllers || NAVIGATION_SECTIONS.fetch(section)).include?(controller_path)
    classes = if compact
      "block rounded-lg px-3 py-2 text-sm font-semibold #{active ? 'bg-blue-50 text-blue-800' : 'text-slate-700 hover:bg-slate-50 hover:text-slate-950'}"
    else
      "rounded-md px-2 py-1.5 text-sm font-semibold #{active ? 'bg-blue-50 text-blue-800' : 'text-slate-600 hover:bg-slate-50 hover:text-slate-950'}"
    end

    link_to label, path, class: classes, aria: (active ? { current: "page" } : {})
  end

  def section_active?(section)
    NAVIGATION_SECTIONS.fetch(section).include?(controller_path)
  end

  def workflow_step_state(experiment, step)
    review_round = experiment.review_round
    judge_round = review_round&.judge_round
    final_translation = experiment.final_translation

    case step
    when :translation
      experiment.failed? ? :failed : (experiment.completed? ? :complete : :current)
    when :review
      return :waiting unless review_round
      review_round.failed? ? :failed : (review_round.completed? ? :complete : :current)
    when :judge
      return :waiting unless judge_round
      judge_round.failed? ? :failed : (judge_round.completed? ? :complete : :current)
    when :editor
      return :waiting unless final_translation
      final_translation.finalized? ? :complete : :current
    end
  end

  def workflow_step_path(experiment, step)
    case step
    when :translation then experiment_path(experiment)
    when :review then review_round_path(experiment.review_round) if experiment.review_round
    when :judge then judge_round_path(experiment.review_round.judge_round) if experiment.review_round&.judge_round
    when :editor then final_translation_path(experiment.final_translation) if experiment.final_translation
    end
  end

  def workflow_step_classes(state)
    case state
    when :complete then "border-emerald-200 bg-emerald-50 text-emerald-900"
    when :current then "border-blue-300 bg-blue-50 text-blue-950"
    when :failed then "border-red-200 bg-red-50 text-red-900"
    else "border-slate-200 bg-white text-slate-500"
    end
  end

  def experiment_next_action(experiment)
    if experiment.final_translation
      return [ "Final translation (#{experiment.final_translation.status.humanize})", final_translation_path(experiment.final_translation) ]
    end
    if experiment.pipeline_run&.status.in?(%w[running blocked ready_for_editor])
      return [ "Pipeline progress", pipeline_run_path(experiment.pipeline_run) ]
    end

    judge_round = experiment.review_round&.judge_round
    return [ judge_round.completed? ? "Judge results" : "View judge progress", judge_round_path(judge_round) ] if judge_round
    return [ experiment.review_round.completed? ? "Continue to judging" : "View blind review", review_round_path(experiment.review_round) ] if experiment.review_round

    [ experiment.completed? ? "Continue to blind review" : "View translation progress", experiment_path(experiment) ]
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
