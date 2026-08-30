require "json"

module Judging
  class ResponseValidator
    class Error < Ai::OpenRouterClient::RetryableError
      def initialize(message)
        super(message, code: "invalid_judge_response")
      end
    end

    ROOT_KEYS = Judging::Prompt::ROOT_FIELDS.sort.freeze
    RANKING_KEYS = Judging::Prompt::RANKING_FIELDS.sort.freeze
    TEXT_FIELDS = %w[rationale strengths risks].freeze

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

      rankings = payload["rankings"]
      invalid!("rankings must be an array") unless rankings.is_a?(Array)
      validated = rankings.map { |ranking| validate_ranking(ranking) }
      validate_complete_set!(validated)
      validate_winner!(payload, validated)
      validate_string!(payload["winner_rationale"], "winner_rationale")
      validate_score!(payload["confidence_score"], "confidence_score")
      invalid!("judgment payload is too large") if JSON.generate(payload).bytesize > 100_000

      payload
    rescue JSON::ParserError => error
      raise Error.new("Judge returned malformed JSON"), cause: error
    end

    private

    attr_reader :content, :expected_labels

    def validate_ranking(ranking)
      invalid!("each ranking must be an object") unless ranking.is_a?(Hash)
      invalid!("ranking fields are invalid") unless ranking.keys.sort == RANKING_KEYS
      label = ranking["candidate_label"]
      invalid!("candidate label is invalid") unless label.is_a?(String) && expected_labels.include?(label)
      rank = ranking["rank"]
      unless rank.is_a?(Integer) && rank.between?(1, expected_labels.size)
        invalid!("rank must be a valid integer")
      end
      validate_score!(ranking["overall_score"], "overall_score")
      TEXT_FIELDS.each { |field| validate_string!(ranking[field], field) }
      ranking
    end

    def validate_complete_set!(rankings)
      labels = rankings.map { |ranking| ranking.fetch("candidate_label") }
      ranks = rankings.map { |ranking| ranking.fetch("rank") }
      unless labels.sort == expected_labels && labels.uniq.size == labels.size
        invalid!("candidate labels must appear exactly once")
      end
      unless ranks.sort == (1..expected_labels.size).to_a && ranks.uniq.size == ranks.size
        invalid!("ranks must form one complete unique sequence")
      end
    end

    def validate_winner!(payload, rankings)
      winner = payload["winner_label"]
      invalid!("winner_label is invalid") unless winner.is_a?(String) && expected_labels.include?(winner)
      rank_one = rankings.find { |ranking| ranking["rank"] == 1 }
      invalid!("winner_label must match rank 1") unless winner == rank_one["candidate_label"]
    end

    def validate_score!(value, field)
      invalid!("#{field} must be an integer from 1 to 100") unless value.is_a?(Integer) && value.between?(1, 100)
    end

    def validate_string!(value, field)
      invalid!("#{field} must be a nonempty string") unless value.is_a?(String) && value.present?
      invalid!("#{field} is too long") if value.length > 5_000
    end

    def invalid!(detail)
      raise Error, "Judge response was invalid: #{detail}"
    end
  end
end
