module TranslationSegments
  class ReconcileRun
    def self.call(translation_run)
      changed = false
      translation_run.with_lock do
        children = translation_run.translation_segment_runs.includes(:experiment_segment).lock.reload.to_a
        attributes = aggregate_attributes(translation_run, children)
        translation_run.assign_attributes(attributes)
        if translation_run.has_changes_to_save?
          translation_run.save!
          changed = true
        end
      end
      TranslationExperiments::ReconcileExperiment.call(translation_run.experiment) if changed
      translation_run
    end

    def self.aggregate_attributes(translation_run, children)
      return { status: :running, translated_text: nil, completed_at: nil } if children.empty? || children.any? { |child| !child.terminal? }
      if children.any?(&:failed?)
        return {
          status: :failed,
          translated_text: nil,
          completed_at: translation_run.completed_at || Time.current,
          error_code: "segment_execution_failed",
          error_message: "One or more translation segments failed. Retry failed segment work explicitly.",
          **Ai::SegmentAggregation.telemetry_attributes(children)
        }
      end

      parts = children.map { |child| [ child.experiment_segment, child.translated_text ] }
      translated_text = LongDocuments::SegmentReassembler.call(parts)
      unless translated_text.present? && translated_text.length <= Ai::UsageLimits::MAX_SOURCE_CHARACTERS
        return {
          status: :failed,
          translated_text: nil,
          completed_at: translation_run.completed_at || Time.current,
          error_code: "translated_document_too_large",
          error_message: "The assembled translation exceeded the safe document length.",
          **Ai::SegmentAggregation.telemetry_attributes(children)
        }
      end

      {
        status: :completed,
        translated_text: translated_text,
        completed_at: translation_run.completed_at || Time.current,
        resolved_model_identifier: Ai::SegmentAggregation.common_value(children, :resolved_model_identifier),
        error_code: nil,
        error_message: nil,
        **Ai::SegmentAggregation.telemetry_attributes(children)
      }
    end
    private_class_method :aggregate_attributes
  end
end
