module Judging
  class Start
    class Error < StandardError; end
    class InvalidReviewStateError < Error; end
    class InsufficientCandidatesError < Error; end
    class IncompleteReviewDataError < Error; end
    class InvalidJudgeSelectionError < Error; end
    class AlreadyStartedError < Error; end

    def self.call(review_round:, judge_ids:)
      new(review_round: review_round, judge_ids: judge_ids).call
    end

    def initialize(review_round:, judge_ids:, randomizer: nil)
      @review_round = review_round
      @judge_ids = Array(judge_ids)
      @randomizer = randomizer || ->(candidates) { candidates.shuffle }
    end

    def call
      validate_review_round!
      judges = resolve_judges!

      JudgeRound.transaction do
        review_round.experiment.lock!
        review_round.lock!
        validate_eligibility!
        candidates = eligible_candidates
        validate_candidates!(candidates)
        validate_review_data!(candidates)
        review_round.association(:judge_round).reset

        if review_round.judge_round
          return existing_round_for!(judges)
        end

        create_round!(judges, candidates)
      end
    end

    private

    attr_reader :judge_ids, :randomizer, :review_round

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
      submitted = judge_ids.map(&:to_s).reject(&:blank?)
      if submitted.empty? || submitted.any? { |id| !id.match?(/\A[1-9]\d*\z/) }
        raise InvalidJudgeSelectionError,
              "Select at least one valid judge model"
      end

      ids = submitted.map(&:to_i).uniq.sort
      judges = LlmModel.where(id: ids).order(:id).to_a
      eligible = judges.map(&:id) == ids && judges.all? do |model|
        model.active? && model.gateway == "openrouter"
      end
      unless eligible
        raise InvalidJudgeSelectionError,
              "Every judge must be an active OpenRouter model"
      end

      judges
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

    def create_round!(judges, candidates)
      judge_round = review_round.create_judge_round!(status: :running)

      judges.each do |judge|
        judge_run = judge_round.judge_runs.create!(judge_llm_model: judge)
        randomized_candidates(candidates).each_with_index do |translation_run, index|
          judge_run.judge_evaluations.create!(
            translation_run: translation_run,
            anonymous_label: BlindReviews::CandidateLabel.for(index)
          )
        end
        JudgeRunJob.perform_later(judge_run.id)
      end

      judge_round
    end

    def randomized_candidates(candidates)
      randomized = Array(randomizer.call(candidates.dup))
      return randomized if randomized.map(&:id).sort == candidates.map(&:id).sort

      raise ArgumentError, "Randomizer must return every candidate exactly once"
    end
  end
end
