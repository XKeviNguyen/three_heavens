module ModelCatalog
  class UsageSummary
    Usage = Data.define(
      :translation_run_count,
      :review_run_count,
      :judge_run_count,
      :finalization_run_count,
      :official_win_count
    )

    def self.call(model_ids:)
      new(model_ids: model_ids).call
    end

    def initialize(model_ids:)
      @model_ids = model_ids
    end

    def call
      return {} if model_ids.empty?

      translations = TranslationRun.where(llm_model_id: model_ids).group(:llm_model_id).count
      reviews = ReviewRun.where(reviewer_llm_model_id: model_ids).group(:reviewer_llm_model_id).count
      judges = JudgeRun.where(judge_llm_model_id: model_ids).group(:judge_llm_model_id).count
      finalizations = FinalizationRun.where(finalizer_llm_model_id: model_ids)
        .group(:finalizer_llm_model_id).count
      wins = official_wins

      model_ids.index_with do |model_id|
        Usage.new(
          translation_run_count: translations.fetch(model_id, 0),
          review_run_count: reviews.fetch(model_id, 0),
          judge_run_count: judges.fetch(model_id, 0),
          finalization_run_count: finalizations.fetch(model_id, 0),
          official_win_count: wins.fetch(model_id, 0)
        )
      end
    end

    private

    attr_reader :model_ids

    def official_wins
      JudgeRound
        .joins(:winner_translation_run)
        .where(status: :completed, translation_runs: { llm_model_id: model_ids })
        .group("translation_runs.llm_model_id")
        .count
    end
  end
end
