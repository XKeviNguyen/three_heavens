module BlindReviews
  class Start
    class Error < StandardError; end
    class InvalidExperimentStateError < Error; end
    class InsufficientCandidatesError < Error; end
    class InvalidReviewerSelectionError < Error; end
    class AlreadyStartedError < Error; end

    def self.call(experiment:, reviewer_ids:)
      new(experiment: experiment, reviewer_ids: reviewer_ids).call
    end

    def initialize(experiment:, reviewer_ids:, randomizer: nil)
      @experiment = experiment
      @reviewer_ids = Array(reviewer_ids)
      @randomizer = randomizer || ->(candidates) { candidates.shuffle }
    end

    def call
      validate_experiment!
      reviewers = resolve_reviewers!

      ReviewRound.transaction do
        experiment.lock!
        validate_completed_experiment!
        candidates = eligible_candidates
        validate_candidates!(candidates)
        experiment.association(:review_round).reset

        if experiment.review_round
          return existing_round_for!(reviewers)
        end

        create_round!(reviewers, candidates)
      end
    end

    private

    attr_reader :experiment, :reviewer_ids, :randomizer

    def validate_experiment!
      raise ActiveRecord::RecordNotSaved, "Experiment must be persisted" unless experiment.persisted?
      raise ActiveRecord::RecordInvalid, experiment unless experiment.valid?
    end

    def validate_completed_experiment!
      return if experiment.completed?

      raise InvalidExperimentStateError,
            "Blind review requires a completed experiment"
    end

    def resolve_reviewers!
      submitted = reviewer_ids.map(&:to_s).reject(&:blank?)
      if submitted.empty? || submitted.any? { |id| !id.match?(/\A[1-9]\d*\z/) }
        raise InvalidReviewerSelectionError,
              "Select at least one valid reviewer model"
      end

      ids = submitted.map(&:to_i).uniq.sort
      reviewers = LlmModel.where(id: ids).order(:id).to_a

      unless reviewers.map(&:id) == ids && reviewers.all? { |model| model.active? && model.gateway == "openrouter" }
        raise InvalidReviewerSelectionError,
              "Every reviewer must be an active OpenRouter model"
      end

      reviewers
    end

    def eligible_candidates
      experiment.translation_runs.completed.includes(:llm_model).select do |run|
        run.translated_text.present?
      end
    end

    def validate_candidates!(candidates)
      return if candidates.size >= 2

      raise InsufficientCandidatesError,
            "Blind review requires at least two completed translations"
    end

    def existing_round_for!(reviewers)
      review_round = experiment.review_round
      existing_ids = review_round.review_runs.pluck(:reviewer_llm_model_id).sort
      return review_round if existing_ids == reviewers.map(&:id)

      raise AlreadyStartedError,
            "A blind review round already exists for this experiment"
    end

    def create_round!(reviewers, candidates)
      review_round = experiment.create_review_round!(status: :running)

      reviewers.each do |reviewer|
        review_run = review_round.review_runs.create!(reviewer_llm_model: reviewer)
        randomized_candidates(candidates).each_with_index do |translation_run, index|
          review_run.review_evaluations.create!(
            translation_run: translation_run,
            anonymous_label: CandidateLabel.for(index)
          )
        end
        ReviewRunJob.perform_later(review_run.id)
      end

      review_round
    end

    def randomized_candidates(candidates)
      randomized = Array(randomizer.call(candidates.dup))
      return randomized if randomized.map(&:id).sort == candidates.map(&:id).sort

      raise ArgumentError, "Randomizer must return every candidate exactly once"
    end
  end
end
