module Judging
  class Start
    class Error < StandardError; end
    class InvalidReviewStateError < Error; end
    class InsufficientCandidatesError < Error; end
    class IncompleteReviewDataError < Error; end
    class InvalidJudgeSelectionError < Error; end
    class AlreadyStartedError < Error; end
    class ContextBudgetError < Error; end

    def self.call(review_round:, judge_ids:, capability_snapshots: {})
      new(review_round: review_round, judge_ids: judge_ids, capability_snapshots: capability_snapshots).call
    end

    def initialize(review_round:, judge_ids:, randomizer: nil, capability_snapshots: {})
      @review_round = review_round
      @judge_ids = judge_ids
      @randomizer = randomizer || ->(candidates) { candidates.shuffle }
      @capability_snapshots = capability_snapshots
    end

    def call
      validate_review_round!
      judges = resolve_judges!
      plan = LongDocuments::Planner.call(review_round.experiment, create: false)

      judge_round, schedules = JudgeRound.transaction do
        review_round.experiment.lock!
        review_round.lock!
        validate_eligibility!
        candidates = eligible_candidates
        validate_candidates!(candidates)
        validate_review_data!(candidates)
        review_round.association(:judge_round).reset

        if review_round.judge_round
          [ existing_round_for!(judges), [] ]
        else
          create_round!(judges, candidates, plan)
        end
      end
      Ai::RunScheduler.enqueue_all(schedules)
      judge_round
    rescue Ai::ContextBudget::Error => error
      raise ContextBudgetError, error.message
    rescue LongDocuments::Planner::SourceChangedError => error
      raise ContextBudgetError, error.message
    end

    private

    attr_reader :capability_snapshots, :judge_ids, :randomizer, :review_round

    def validate_review_round!
      unless review_round.persisted? && review_round.experiment.persisted?
        raise ActiveRecord::RecordNotSaved,
              "Review round and experiment must be persisted"
      end
    end

    def validate_eligibility!
      unless review_round.experiment.completed? && review_round.completed?
        raise InvalidReviewStateError,
              "Judging requires a completed experiment and blind review round"
      end
    end

    def resolve_judges!
      ids = Ai::UsageLimits.normalize_model_ids(
        judge_ids,
        maximum: Ai::UsageLimits::MAX_JUDGES,
        label: "Judges"
      )
      judges = LlmModel.where(id: ids).order(:id).to_a
      eligible = judges.map(&:id) == ids && judges.all? do |model|
        model.active? && model.gateway == "openrouter"
      end
      unless eligible
        raise InvalidJudgeSelectionError,
              "Every judge must be an active OpenRouter model"
      end

      judges
    rescue Ai::UsageLimits::InvalidSelection => error
      raise InvalidJudgeSelectionError, error.message
    end

    def eligible_candidates
      review_round.experiment.translation_runs.completed.select do |run|
        run.translated_text.present?
      end
    end

    def validate_candidates!(candidates)
      return if candidates.size >= 2

      raise InsufficientCandidatesError,
            "Judging requires at least two completed translations"
    end

    def validate_review_data!(candidates)
      candidate_ids = candidates.map(&:id).sort
      complete = review_round.review_runs.reload.any? &&
        review_round.review_runs.all? do |run|
          evaluations = run.review_evaluations.to_a
          run.completed? &&
            evaluations.map(&:translation_run_id).sort == candidate_ids &&
            evaluations.all?(&:complete?)
        end
      return if complete

      raise IncompleteReviewDataError,
            "Every candidate needs complete blind-review feedback from every reviewer"
    end

    def existing_round_for!(judges)
      judge_round = review_round.judge_round
      existing_ids = judge_round.judge_runs.pluck(:judge_llm_model_id).sort
      return judge_round if existing_ids == judges.map(&:id)

      raise AlreadyStartedError,
            "A judge round already exists for this blind review"
    end

    def create_round!(judges, candidates, plan)
      judge_round = review_round.create_judge_round!(status: :running)
      schedules = []

      judges.each do |judge|
        judge_run = judge_round.judge_runs.create!(judge_llm_model: judge)
        randomized_candidates(candidates).each_with_index do |translation_run, index|
          judge_run.judge_evaluations.create!(
            translation_run: translation_run,
            anonymous_label: BlindReviews::CandidateLabel.for(index)
          )
        end
        if plan
          judge_run.update!(status: :running, started_at: Time.current)
          plan.segments.each do |segment|
            prompt = Judging::Prompt.build(judge_run, experiment_segment: segment)
            budget = TranslationReferences::ContextBudget.call(
              experiment: review_round.experiment,
              model: judge,
              stage: :judge,
              source_character_count: review_round.experiment.document.source_text.length,
              capability_snapshot: capability_snapshots[judge.id],
              prompt: prompt
            ) { Judging::Prompt.build(judge_run, experiment_segment: segment, reference_examples: []) }
            segment_run = judge_run.judge_segment_runs.create!(
              experiment_segment: segment,
              **budget.snapshot_attributes
            )
            schedules << Ai::RunScheduler.prepare(run: segment_run, job_class: JudgeSegmentRunJob)
          end
        else
          prompt = Judging::Prompt.build(judge_run)
          budget = TranslationReferences::ContextBudget.call(
            experiment: review_round.experiment,
            model: judge,
            stage: :judge,
            source_character_count: review_round.experiment.document.source_text.length,
            capability_snapshot: capability_snapshots[judge.id],
            prompt: prompt
          ) { Judging::Prompt.build(judge_run, reference_examples: []) }
          judge_run.assign_attributes(**budget.snapshot_attributes)
          schedules << Ai::RunScheduler.prepare(run: judge_run, job_class: JudgeRunJob)
        end
      end

      [ judge_round, schedules ]
    end

    def randomized_candidates(candidates)
      randomized = Array(randomizer.call(candidates.dup))
      return randomized if randomized.map(&:id).sort == candidates.map(&:id).sort

      raise ArgumentError, "Randomizer must return every candidate exactly once"
    end
  end
end
