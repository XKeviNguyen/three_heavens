require "digest"

module LongDocuments
  class Planner
    class SourceChangedError < StandardError; end

    def self.call(experiment, create: true)
      new(experiment, create: create).call
    end

    def initialize(experiment, create:)
      @experiment = experiment
      @create = create
    end

    def call
      DocumentExecutionPlan.transaction do
        experiment.lock!
        document = experiment.document
        document.lock!
        source = document.reload.source_text
        experiment.association(:document_execution_plan).reset
        return validate_existing!(experiment.document_execution_plan, source) if experiment.document_execution_plan
        return unless create
        return if source.length <= LongDocuments::Segmenter::TARGET_CHARACTERS

        segments = LongDocuments::Segmenter.call(source)

        plan = experiment.create_document_execution_plan!(
          segmentation_version: LongDocuments::Segmenter::VERSION,
          budget_policy_version: Ai::ContextBudget::POLICY_VERSION,
          source_sha256: Digest::SHA256.hexdigest(source),
          segment_count: segments.size,
          segment_target_characters: LongDocuments::Segmenter::TARGET_CHARACTERS
        )
        segments.each do |segment|
          plan.segments.create!(
            position: segment.position,
            source_text: segment.source_text,
            source_character_count: segment.source_text.length,
            source_sha256: segment.source_sha256
          )
        end
        plan
      end
    end

    private

    attr_reader :create, :experiment

    def validate_existing!(plan, source)
      unless plan.source_sha256 == Digest::SHA256.hexdigest(source) && plan.reconstruct_source == source
        raise SourceChangedError, "The stored long-document plan no longer matches the authoritative source"
      end
      plan
    end
  end
end
