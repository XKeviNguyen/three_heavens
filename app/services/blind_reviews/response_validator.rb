require "json"

module BlindReviews
  class ResponseValidator
    class Error < Ai::OpenRouterClient::RetryableError
      def initialize(message)
        super(message, code: "invalid_review_response")
      end
    end

    ROOT_KEYS = [ "evaluations" ].freeze
    EVALUATION_KEYS = BlindReviews::Prompt::REQUIRED_FIELDS.sort.freeze
    SCORE_FIELDS = BlindReviews::Prompt::SCORE_FIELDS.freeze
    FEEDBACK_FIELDS = %w[strengths issues recommended_corrections].freeze

    def self.call(content:, expected_labels:)
      new(content: content, expected_labels: expected_labels).call
    end

    def initialize(content:, expected_labels:)
      @content = content
      @expected_labels = expected_labels.sort
    end

    def call
      payload = JSON.parse(content)
      invalid!("root must be an object") unless payload.is_a?(Hash)
      invalid!("unexpected root fields") unless payload.keys.sort == ROOT_KEYS

      evaluations = payload["evaluations"]
      invalid!("evaluations must be an array") unless evaluations.is_a?(Array)

      validated = evaluations.map { |evaluation| validate_evaluation(evaluation) }
      labels = validated.map { |evaluation| evaluation.fetch("candidate_label") }
      invalid!("candidate labels must appear exactly once") unless labels.sort == expected_labels && labels.uniq.size == labels.size

      validated
    rescue JSON::ParserError => error
      raise Error.new("Reviewer returned malformed JSON"), cause: error
    end

    private

    attr_reader :content, :expected_labels

    def validate_evaluation(evaluation)
      invalid!("each evaluation must be an object") unless evaluation.is_a?(Hash)
      invalid!("evaluation fields are invalid") unless evaluation.keys.sort == EVALUATION_KEYS

      label = evaluation["candidate_label"]
      invalid!("candidate label is invalid") unless label.is_a?(String) && expected_labels.include?(label)

      SCORE_FIELDS.each do |field|
        score = evaluation[field]
        invalid!("#{field} must be an integer from 1 to 10") unless score.is_a?(Integer) && score.between?(1, 10)
      end

      FEEDBACK_FIELDS.each do |field|
        feedback = evaluation[field]
        invalid!("#{field} must be a string") unless feedback.is_a?(String)
        invalid!("#{field} is too long") if feedback.length > 5_000
      end

      suggestion = evaluation["suggested_translation"]
      invalid!("suggested_translation must be a string or null") unless suggestion.nil? || suggestion.is_a?(String)
      invalid!("suggested_translation is too long") if suggestion&.length.to_i > 50_000

      evaluation
    end

    def invalid!(detail)
      raise Error, "Reviewer response was invalid: #{detail}"
    end
  end
end
