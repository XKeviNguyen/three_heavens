module ReviewSegments
  class ReconcileRun
    SCORE_FIELDS = BlindReviews::Prompt::SCORE_FIELDS.freeze
    TEXT_FIELDS = %w[strengths issues recommended_corrections].freeze

    def self.call(review_run)
      changed = false
      ReviewRun.transaction do
        review_run.lock!
        children = review_run.review_segment_runs.includes(:experiment_segment).lock.reload.to_a
        attributes = aggregate_attributes(review_run, children)
        review_run.assign_attributes(attributes)
        if review_run.has_changes_to_save?
          review_run.save!
          changed = true
        end
      end
      BlindReviews::ReconcileRound.call(review_run.review_round) if changed
      review_run
    end

    def self.aggregate_attributes(review_run, children)
      return { status: :running, completed_at: nil } if children.empty? || children.any? { |child| !child.terminal? }
      if children.any?(&:failed?)
        return {
          status: :failed,
          completed_at: review_run.completed_at || Time.current,
          error_code: "segment_execution_failed",
          error_message: "One or more review segments failed. Retry failed segment work explicitly.",
          **Ai::SegmentAggregation.telemetry_attributes(children)
        }
      end

      persist_evaluations!(review_run, children)
      {
        status: :completed,
        completed_at: review_run.completed_at || Time.current,
        resolved_model_identifier: Ai::SegmentAggregation.common_value(children, :resolved_model_identifier),
        error_code: nil,
        error_message: nil,
        **Ai::SegmentAggregation.telemetry_attributes(children)
      }
    end
    private_class_method :aggregate_attributes

    def self.persist_evaluations!(review_run, children)
      evaluations_by_label = review_run.review_evaluations.lock.index_by(&:anonymous_label)
      weights = children.to_h { |child| [ child.id, child.experiment_segment.source_character_count ] }
      total_weight = weights.values.sum

      evaluations_by_label.each do |label, stored|
        segment_values = children.map do |child|
          [ child, child.evaluations.find { |item| item.fetch("candidate_label") == label } ]
        end
        raise ActiveRecord::RecordNotFound, "Segment review evaluation is missing" if segment_values.any? { |_, item| item.nil? }

        attributes = SCORE_FIELDS.to_h do |field|
          weighted = segment_values.sum { |child, item| item.fetch(field) * weights.fetch(child.id) }
          [ field, (weighted.fdiv(total_weight)).round ]
        end
        TEXT_FIELDS.each do |field|
          attributes[field] = bounded_feedback(segment_values, field, 5_000)
        end
        suggestions = segment_values.map { |_, item| item["suggested_translation"] }
        attributes["suggested_translation"] = if suggestions.all?(&:present?)
          parts = segment_values.map do |child, item|
            [ child.experiment_segment, item.fetch("suggested_translation") ]
          end
          assembled = LongDocuments::SegmentReassembler.call(parts)
          assembled if assembled.length <= 50_000
        end
        stored.update!(attributes)
      end
    end
    private_class_method :persist_evaluations!

    def self.bounded_feedback(segment_values, field, maximum)
      values = segment_values.map do |child, item|
        "Segment #{child.experiment_segment.position}: #{item.fetch(field)}"
      end
      Ai::SegmentAggregation.bounded_join(values, maximum: maximum)
    end
    private_class_method :bounded_feedback
  end
end
