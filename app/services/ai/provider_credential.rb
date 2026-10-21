module Ai
  # A resolved OpenRouter key, held only in memory for one claimed execution.
  # It is never serialized into job arguments, logs, events, or records, and
  # its inspect/to_s output is redacted.
  class ProviderCredential
    attr_reader :billing_source

    # The admin-saved key (ManagedOpenRouterKey), else OPENROUTER_API_KEY.
    def self.managed
      new(billing_source: "managed", api_key: ManagedOpenRouterKey.effective_api_key)
    end

    def self.personal(api_key)
      new(billing_source: "personal", api_key: api_key)
    end

    def initialize(billing_source:, api_key:)
      @billing_source = billing_source
      @api_key = api_key
      freeze
    end

    def api_key
      @api_key
    end

    def inspect
      "#<#{self.class.name} billing_source=#{billing_source} [FILTERED]>"
    end
    alias_method :to_s, :inspect
  end
end
