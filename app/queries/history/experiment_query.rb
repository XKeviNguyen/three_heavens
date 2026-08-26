module History
  class ExperimentQuery
    PER_PAGE = 25

    Page = Data.define(:entries, :current_page, :total_pages, :total_count, :per_page) do
      def previous_page
        current_page - 1 if current_page > 1
      end

      def next_page
        current_page + 1 if current_page < total_pages
      end
    end

    Entry = Data.define(
      :experiment,
      :translation_candidate_count,
      :known_system_cost,
      :cost_sample_count,
      :cost_record_count
    ) do
      def cost_telemetry_complete?
        cost_record_count.positive? && cost_sample_count == cost_record_count
      end

      def cost_telemetry_incomplete?
        cost_record_count.positive? && !cost_telemetry_complete?
      end
    end

    def initialize(page: nil)
      @requested_page = parse_page(page)
    end

    def call
      total_count = Experiment.count
      total_pages = [ (total_count.to_f / PER_PAGE).ceil, 1 ].max
      current_page = [ @requested_page, total_pages ].min
      experiments = experiment_scope.offset((current_page - 1) * PER_PAGE).limit(PER_PAGE).to_a
      costs = cost_aggregates(experiments.map(&:id))

      Page.new(
        entries: experiments.map { |experiment| build_entry(experiment, costs) },
        current_page: current_page,
        total_pages: total_pages,
        total_count: total_count,
        per_page: PER_PAGE
      )
    end

    private

    def parse_page(value)
      parsed = Integer(value, exception: false)
      parsed&.positive? ? parsed : 1
    end

    def experiment_scope
      Experiment.includes(
        { document: :project },
        :translation_runs,
        review_round: { judge_round: { winner_translation_run: :llm_model } }
      ).order(created_at: :desc, id: :desc)
    end

    def cost_aggregates(experiment_ids)
      totals = Hash.new do |hash, experiment_id|
        hash[experiment_id] = { known: BigDecimal("0"), samples: 0, records: 0 }
      end
      return totals if experiment_ids.empty?

      merge_cost_rows(totals, translation_cost_rows(experiment_ids))
      merge_cost_rows(totals, review_cost_rows(experiment_ids))
      merge_cost_rows(totals, judge_cost_rows(experiment_ids))
      totals
    end

    def translation_cost_rows(experiment_ids)
      TranslationRun.where(experiment_id: experiment_ids)
        .group(:experiment_id)
        .pluck(:experiment_id, Arel.sql("SUM(cost)"), Arel.sql("COUNT(cost)"), Arel.sql("COUNT(*)"))
    end

    def review_cost_rows(experiment_ids)
      ReviewRun.joins(:review_round)
        .where(review_rounds: { experiment_id: experiment_ids })
        .group("review_rounds.experiment_id")
        .pluck(
          "review_rounds.experiment_id",
          Arel.sql("SUM(review_runs.cost)"),
          Arel.sql("COUNT(review_runs.cost)"),
          Arel.sql("COUNT(*)")
        )
    end

    def judge_cost_rows(experiment_ids)
      JudgeRun.joins(judge_round: :review_round)
        .where(review_rounds: { experiment_id: experiment_ids })
        .group("review_rounds.experiment_id")
        .pluck(
          "review_rounds.experiment_id",
          Arel.sql("SUM(judge_runs.cost)"),
          Arel.sql("COUNT(judge_runs.cost)"),
          Arel.sql("COUNT(*)")
        )
    end

    def merge_cost_rows(totals, rows)
      rows.each do |experiment_id, known, samples, records|
        total = totals[experiment_id]
        total[:known] += BigDecimal(known.to_s) unless known.nil?
        total[:samples] += samples
        total[:records] += records
      end
    end

    def build_entry(experiment, costs)
      cost = costs[experiment.id]
      Entry.new(
        experiment: experiment,
        translation_candidate_count: experiment.translation_runs.size,
        known_system_cost: cost[:samples].positive? ? cost[:known] : nil,
        cost_sample_count: cost[:samples],
        cost_record_count: cost[:records]
      )
    end
  end
end
