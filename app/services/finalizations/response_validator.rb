require "json"

module Finalizations
  class ResponseValidator
    MAX_LIST_ITEMS = 20
    MAX_ITEM_LENGTH = 1_000

    class Error < Ai::OpenRouterClient::RetryableError
      def initialize(message)
        super(message, code: "invalid_finalization_response")
      end
    end

    ROOT_KEYS = Finalizations::Prompt::ROOT_FIELDS.sort.freeze
    LIST_FIELDS = %w[change_summary terminology_notes warnings].freeze

    def self.call(content:)
      new(content: content).call
    end

    def initialize(content:)
      @content = content
    end

    def call
      payload = JSON.parse(content)
      invalid!("root must be an object") unless payload.is_a?(Hash)
      invalid!("unexpected root fields") unless payload.keys.sort == ROOT_KEYS

      proposal = payload["proposed_translation"]
      unless proposal.is_a?(String) && proposal.present?
        invalid!("proposed_translation must be a nonblank string")
      end
      if proposal.length > FinalTranslationVersion::MAX_CONTENT_LENGTH
        invalid!("proposed_translation is too long")
      end

      LIST_FIELDS.each { |field| validate_list!(payload[field], field) }
      payload
    rescue JSON::ParserError => error
      raise Error.new("Finalizer returned malformed JSON"), cause: error
    end

    private

    attr_reader :content

    def validate_list!(value, field)
      invalid!("#{field} must be an array") unless value.is_a?(Array)
      invalid!("#{field} has too many items") if value.size > MAX_LIST_ITEMS
      value.each do |item|
        invalid!("#{field} must contain strings only") unless item.is_a?(String)
        invalid!("#{field} item is too long") if item.length > MAX_ITEM_LENGTH
      end
    end

    def invalid!(detail)
      raise Error, "Finalizer response was invalid: #{detail}"
    end
  end
end
