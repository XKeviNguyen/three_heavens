module Ai
  module RetryEnqueueGuard
    extend ActiveSupport::Concern

    included do
      class_attribute :ai_run_class, instance_writer: false
    end

    private

    def retry_job(options = {})
      result = super
      return result if result

      fail_current_run_enqueue
      false
    rescue SolidQueue::Job::EnqueueError
      fail_current_run_enqueue
      false
    end

    def fail_current_run_enqueue
      Ai::RunScheduler.fail_running(
        run_class: self.class.ai_run_class,
        run_id: arguments.first,
        attempt: claimed_attempt
      )
    end
  end
end
