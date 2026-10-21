module BlindReviews
  # Replaces one failed reviewer with another model inside the same round.
  # The failed run keeps its status, attempts and cost and is marked as
  # superseded by the new run, which reviews the same anonymous candidates.
  # Only the new run's work is billed, under the payer shown on the page
  # (Ai::BillingPolicy.authorize_confirmed!). The round runs again, and judging
  # can start once every current reviewer has succeeded.
  class ReplaceFailed
    class Error < StandardError; end
    class NotReplaceableError < Error; end
    class DuplicateModelError < Error; end

    def self.call(review_round:, review_run_id:, replacement:, billing:)
      new(review_round:, review_run_id:, replacement:, billing:).call
    end

    def initialize(review_round:, review_run_id:, replacement:, billing:)
      @review_round = review_round
      @review_run_id = review_run_id
      @replacement = replacement
      @billing = billing
    end

    def call
      experiment = review_round.experiment
      plan = LongDocuments::Planner.call(experiment, create: false)
      starter = Start.new(experiment: experiment, reviewer_ids: [], billing: billing)

      new_run, schedules = ReviewRound.transaction do
        experiment.lock!
        review_round.lock!
        failed_run = replaceable_run!
        validate_replacement!

        candidates = failed_run.review_evaluations.includes(:translation_run).map(&:translation_run)
        run, run_schedules = starter.add_reviewer!(review_round, replacement, candidates, plan)
        failed_run.update!(superseded_at: Time.current, superseded_by: run)
        review_round.update!(status: :running)
        [ run, run_schedules ]
      end
      Ai::RunScheduler.enqueue_all(schedules)
      Pipelines::AdvancementScheduler.enqueue_for(experiment)
      new_run
    rescue Ai::ContextBudget::Error, LongDocuments::Planner::SourceChangedError => error
      raise Error, error.message
    end

    private

    attr_reader :billing, :replacement, :review_round, :review_run_id

    def replaceable_run!
      review_round.association(:judge_round).reset
      if review_round.judge_round
        raise NotReplaceableError, "Judging has already started, so reviewers can no longer change"
      end

      run = review_round.review_runs.lock.find_by(id: review_run_id)
      raise NotReplaceableError, "Only a failed reviewer can be replaced" unless run&.failed?

      run
    end

    def validate_replacement!
      unless replacement.active? && replacement.gateway == "openrouter"
        raise NotReplaceableError, "The replacement must be an active OpenRouter model"
      end
      return unless review_round.all_review_runs.exists?(reviewer_llm_model_id: replacement.id)

      raise DuplicateModelError, "That model has already reviewed in this round; choose a different one"
    end
  end
end
