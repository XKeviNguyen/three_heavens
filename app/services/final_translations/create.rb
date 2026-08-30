module FinalTranslations
  class Create
    def self.call(judge_round:)
      new(judge_round: judge_round).call
    end

    def initialize(judge_round:)
      @judge_round = judge_round
    end

    def call
      unless judge_round.persisted?
        raise ActiveRecord::RecordNotSaved, "Judge round must be persisted"
      end

      FinalTranslation.transaction do
        experiment.lock!
        judge_round.lock!
        validate_eligibility!
        judge_round.association(:final_translation).reset
        return judge_round.final_translation if judge_round.final_translation

        create_workspace!
      end
    end

    private

    attr_reader :judge_round

    def experiment
      judge_round.experiment
    end

    def validate_eligibility!
      review_round = judge_round.review_round
      winner = judge_round.winner_translation_run
      eligible = experiment.persisted? && experiment.completed? &&
        review_round&.completed? && judge_round.completed? && winner &&
        winner.experiment_id == experiment.id && winner.completed? &&
        winner.translated_text.present?
      return if eligible

      raise EligibilityError,
            "A final translation requires a completed experiment, review, judge round, and valid official winner"
    end

    def create_workspace!
      winner = judge_round.winner_translation_run
      final_translation = FinalTranslation.new(
        experiment: experiment,
        judge_round: judge_round,
        source_winner_translation_run: winner,
        status: :draft
      )
      final_translation.save!(validate: false)
      seed_version = final_translation.versions.create!(
        version_number: 1,
        content: winner.translated_text,
        origin: :seed,
        segment_alignment_valid: true,
        change_note: "Seeded from the official winning translation"
      )
      winner.translation_segment_runs.includes(:experiment_segment).each do |segment_run|
        seed_version.segments.create!(
          experiment_segment: segment_run.experiment_segment,
          content: segment_run.translated_text
        )
      end
      final_translation.update!(current_version: seed_version)
      final_translation
    end
  end
end
