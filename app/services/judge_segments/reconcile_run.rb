module JudgeSegments
  class ReconcileRun
    TEXT_FIELDS = %w[rationale strengths risks].freeze

    def self.call(judge_run)
      changed = false
      JudgeRun.transaction do
        judge_run.lock!
        children = judge_run.judge_segment_runs.includes(:experiment_segment).lock.reload.to_a
        attributes = aggregate_attributes(judge_run, children)
        judge_run.assign_attributes(attributes)
        if judge_run.has_changes_to_save?
          judge_run.save!
          changed = true
        end
      end
      Judging::ReconcileRound.call(judge_run.judge_round) if changed
      judge_run
    end

    def self.aggregate_attributes(judge_run, children)
      return running_attributes if children.empty? || children.any? { |child| !child.terminal? }
      return failed_attributes(judge_run, children) if children.any?(&:failed?)

      winner_id, rationale = persist_evaluations!(judge_run, children)
      confidence = weighted_confidence(children)
      {
        status: :completed,
        winner_translation_run_id: winner_id,
        winner_rationale: rationale,
        confidence_score: confidence,
        completed_at: judge_run.completed_at || Time.current,
        resolved_model_identifier: Ai::SegmentAggregation.common_value(children, :resolved_model_identifier),
        error_code: nil,
        error_message: nil,
        **Ai::SegmentAggregation.telemetry_attributes(children)
      }
    end
    private_class_method :aggregate_attributes

    def self.running_attributes
      { status: :running, winner_translation_run: nil, completed_at: nil }
    end
    private_class_method :running_attributes

    def self.failed_attributes(judge_run, children)
      {
        status: :failed,
        winner_translation_run: nil,
        completed_at: judge_run.completed_at || Time.current,
        error_code: "segment_execution_failed",
        error_message: "One or more judgment segments failed. Retry failed segment work explicitly.",
        **Ai::SegmentAggregation.telemetry_attributes(children)
      }
    end
    private_class_method :failed_attributes

    def self.persist_evaluations!(judge_run, children)
      stored_by_label = judge_run.judge_evaluations.lock.index_by(&:anonymous_label)
      candidate_count = stored_by_label.size
      weights = children.to_h { |child| [ child.id, child.experiment_segment.source_character_count ] }
      total_weight = weights.values.sum
      aggregates = stored_by_label.map do |label, stored|
        rankings = children.map do |child|
          [ child, child.judgment.fetch("rankings").find { |item| item.fetch("candidate_label") == label } ]
        end
        raise ActiveRecord::RecordNotFound, "Segment judgment ranking is missing" if rankings.any? { |_, item| item.nil? }

        points = rankings.sum do |child, ranking|
          weights.fetch(child.id) * (candidate_count - ranking.fetch("rank") + 1)
        end
        score = rankings.sum do |child, ranking|
          weights.fetch(child.id) * ranking.fetch("overall_score")
        end.fdiv(total_weight).round
        { label: label, stored: stored, rankings: rankings, points: points, score: score }
      end
      aggregates.sort_by! { |item| [ -item.fetch(:points), -item.fetch(:score), item.fetch(:stored).translation_run_id ] }
      aggregates.each_with_index do |item, index|
        attributes = { rank: index + 1, overall_score: item.fetch(:score) }
        TEXT_FIELDS.each do |field|
          values = item.fetch(:rankings).map do |child, ranking|
            "Segment #{child.experiment_segment.position}: #{ranking.fetch(field)}"
          end
          attributes[field] = Ai::SegmentAggregation.bounded_join(values, maximum: 5_000)
        end
        item.fetch(:stored).update!(attributes)
      end
      winner = aggregates.first
      [ winner.fetch(:stored).translation_run_id, winner.fetch(:stored).rationale ]
    end
    private_class_method :persist_evaluations!

    def self.weighted_confidence(children)
      total_weight = children.sum { |child| child.experiment_segment.source_character_count }
      weighted = children.sum do |child|
        child.judgment.fetch("confidence_score") * child.experiment_segment.source_character_count
      end
      weighted.fdiv(total_weight).round
    end
    private_class_method :weighted_confidence
  end
end
