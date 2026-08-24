module Ai
  class ErrorSanitizer
    MAX_LENGTH = 1_000

    def self.call(message, secrets: [])
      sanitized = message.to_s.encode("UTF-8", invalid: :replace, undef: :replace)
      sanitized.gsub!(/Bearer\s+\S+/i, "Bearer [FILTERED]")

      secrets.compact_blank.each do |secret|
        sanitized.gsub!(secret, "[FILTERED]")
      end

      sanitized.gsub!(/\s+/, " ")
      sanitized.strip.first(MAX_LENGTH)
    end
  end
end
