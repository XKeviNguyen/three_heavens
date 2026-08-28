module AuthorizedAiJobHelper
  def build_authorized_ai_job(job_class, run, execution: nil, job_id: nil)
    run.reload
    job = job_class.new(run.id)

    if job_id
      job.job_id = job_id
    elsif run.pending? && (run.scheduled_job_id.blank? || run.claimed_job_execution.positive?)
      schedule = Ai::RunScheduler.prepare(run: run, job_class: job_class)
      job = schedule.job
    elsif run.scheduled_job_id.present?
      job.job_id = run.scheduled_job_id
    else
      run.update!(
        scheduled_job_id: job.job_id,
        claimed_job_execution: (run.running? ? 1 : 0),
        pending_since: (Time.current if run.pending?)
      )
    end

    intended_execution = execution || (run.running? ? run.claimed_job_execution : 1)
    job.executions = intended_execution - 1
    job
  end

  def perform_authorized_ai_job(job_class, run, **options)
    build_authorized_ai_job(job_class, run, **options).perform_now
  end

  def enqueue_authorized_ai_job(job_class, run, **options)
    build_authorized_ai_job(job_class, run, **options).enqueue
  end
end
