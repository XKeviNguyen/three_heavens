module FinalizationSegments
  class ReconcileRun
    LIST_FIELDS = %i[change_summary terminology_notes warnings].freeze

    def self.call(finalization_run)
      changed = false
      finalization_run.with_lock do
        children = finalization_run.finalization_segment_runs.includes(:experiment_segment).lock.reload.to_a
        attributes = aggregate_attributes(finalization_run, children)
        finalization_run.assign_attributes(attributes)
        if finalization_run.has_changes_to_save?
          finalization_run.save!
          changed = true
        end
      end
      Finalizations::ReconcileRound.call(finalization_run.finalization_round) if changed
      finalization_run
    end

    def self.aggregate_attributes(finalization_run, children)
      return { status: :running, proposed_translation: nil, completed_at: nil } if children.empty? || children.any? { |child| !child.terminal? }
      if children.any?(&:failed?)
        return {
          status: :failed,
          proposed_translation: nil,
          completed_at: finalization_run.completed_at || Time.current,
          error_code: "segment_execution_failed",
          error_message: "One or more refinement segments failed. Retry failed segment work explicitly.",
          **Ai::SegmentAggregation.telemetry_attributes(children)
        }
      end

      ordered = children.sort_by { |child| child.experiment_segment.position }
      proposal = ordered.map(&:proposed_translation).join
      unless proposal.present? && proposal.length <= FinalTranslationVersion::MAX_CONTENT_LENGTH
        return {
          status: :failed,
          proposed_translation: nil,
          completed_at: finalization_run.completed_at || Time.current,
          error_code: "translated_document_too_large",
          error_message: "The assembled refinement exceeded the safe document length.",
          **Ai::SegmentAggregation.telemetry_attributes(children)
        }
      end

      list_attributes = LIST_FIELDS.to_h do |field|
        [ field, bounded_list(ordered, field) ]
      end
      {
        status: :completed,
        proposed_translation: proposal,
        completed_at: finalization_run.completed_at || Time.current,
        resolved_model_identifier: Ai::SegmentAggregation.common_value(ordered, :resolved_model_identifier),
        error_code: nil,
        error_message: nil,
        **list_attributes,
        **Ai::SegmentAggregation.telemetry_attributes(ordered)
      }
    end
    private_class_method :aggregate_attributes

    def self.bounded_list(children, field)
      values = children.flat_map { |child| child.public_send(field) }
      maximum = Finalizations::ResponseValidator::MAX_LIST_ITEMS
      return values if values.size <= maximum

      values.first(maximum - 1) + [ "Additional segment #{field.to_s.humanize.downcase} omitted." ]
    end
    private_class_method :bounded_list
  end
end
