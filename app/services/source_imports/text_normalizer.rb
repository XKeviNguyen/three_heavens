module SourceImports
  class TextNormalizer
    UTF8_BOM = "\xEF\xBB\xBF".b
    UNSAFE_CONTROL_PATTERN = /[\u0001-\u0008\u000B\u000C\u000E-\u001F\u007F]/

    def self.call(bytes)
      new(bytes).call
    end

    def initialize(bytes)
      @bytes = bytes.to_s.b
    end

    def call
      reject_nul!

      text = bytes.delete_prefix(UTF8_BOM).force_encoding(Encoding::UTF_8)
      raise Error.new("invalid_utf8", "The source file must contain valid UTF-8 text.") unless text.valid_encoding?

      text = text.gsub("\r\n", "\n").tr("\r", "\n")
      reject_binary_controls!(text)
      text = text.gsub(UNSAFE_CONTROL_PATTERN, "")
      raise Error.new("empty_source", "The source file does not contain readable text.") if text.strip.empty?

      if text.length > Limits::MAX_EXTRACTED_CHARACTERS
        raise Error.new(
          "source_too_long",
          "The extracted source has #{text.length} characters; the limit is #{Limits::MAX_EXTRACTED_CHARACTERS}."
        )
      end

      text
    end

    private

    attr_reader :bytes

    def reject_nul!
      return unless bytes.include?("\0")

      raise Error.new("binary_source", "The source file does not appear to be plain text.")
    end

    def reject_binary_controls!(text)
      count = text.scan(UNSAFE_CONTROL_PATTERN).length
      threshold = [ 4, text.length / 100 ].max
      return if count <= threshold

      raise Error.new("binary_source", "The source file does not appear to be plain text.")
    end
  end
end
