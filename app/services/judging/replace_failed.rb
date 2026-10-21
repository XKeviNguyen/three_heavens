module Judging
  # Replaces one failed judge with another model inside the same round. The
  # failed run keeps its status, attempts and cost and is marked as superseded
  # by the new run, which ranks the same anonymous candidates. Only the new
  # run's work is billed, under the payer shown on the page. The round runs
  # again and picks a winner once every current judge has succeeded.
  class ReplaceFailed
    class Error < StandardError; end
    class NotReplaceableError < Error; end
    class DuplicateModelError < Error; end

    def self.call(judge_round:, judge_run_id:, replacement:, billing:)
      new(judge_round:, judge_run_id:, replacement:, billing:).call
    end

    def initialize(judge_round:, judge_run_id:, replacement:, billing:)
      @judge_round = judge_round
      @judge_run_id = judge_run_id
      @replacement = replacement
      @billing = billing
    end

    def call
      review_round = judge_round.review_round
      experiment = review_round.experiment
      plan = LongDocuments::Planner.call(experiment, create: false)
      starter = Start.new(review_round: review_round, judge_ids: [], billing: billing)

      new_run, schedules = JudgeRound.transaction do
        experiment.lock!
        review_round.lock!
        judge_round.lock!
        failed_run = replaceable_run!
        validate_replacement!

        candidates = failed_run.judge_evaluations.includes(:translation_run).map(&:translation_run)
        run, run_schedules = starter.add_judge!(judge_round, replacement, candidates, plan)
        failed_run.update!(superseded_at: Time.current, superseded_by: run)
        judge_round.update!(status: :running, winner_translation_run: nil, aggregate_rankings: [], aggregation_explanation: nil)
        [ run, run_schedules ]
      end
      Ai::RunScheduler.enqueue_all(schedules)
      Pipelines::AdvancementScheduler.enqueue_for(experiment)
      new_run
    rescue Ai::ContextBudget::Error, LongDocuments::Planner::SourceChangedError => error
      raise Error, error.message
    end

    private

    attr_reader :billing, :judge_round, :judge_run_id, :replacement

    def replaceable_run!
      judge_round.association(:final_translation).reset
      if judge_round.final_translation
        raise NotReplaceableError, "The final translation already exists, so judges can no longer change"
      end

      run = judge_round.judge_runs.lock.find_by(id: judge_run_id)
      raise NotReplaceableError, "Only a failed judge can be replaced" unless run&.failed?

      run
    end

    def validate_replacement!
      unless replacement.active? && replacement.gateway == "openrouter"
        raise NotReplaceableError, "The replacement must be an active OpenRouter model"
      end
      return unless judge_round.all_judge_runs.exists?(judge_llm_model_id: replacement.id)

      raise DuplicateModelError, "That model has already judged in this round; choose a different one"
    end
  end
end
