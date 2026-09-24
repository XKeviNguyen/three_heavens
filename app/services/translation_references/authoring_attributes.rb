module TranslationReferences
  class AuthoringAttributes
    class Error < StandardError
      attr_reader :resolved_attributes

      def initialize(message, resolved_attributes: {})
        @resolved_attributes = resolved_attributes
        super(message)
      end
    end

    SIDES = {
      "source_text" => "source_file",
      "approved_translation" => "approved_translation_file"
    }.freeze

    def self.call(attributes)
      new(attributes).call
    end

    def initialize(attributes)
      @attributes = attributes.to_h.stringify_keys
    end

    def call
      resolved = attributes.slice("title", "source_language", "target_language")
      errors = []
      SIDES.each do |text_key, file_key|
        resolved[text_key] = attributes[text_key].to_s
        upload = attributes[file_key]
        begin
          if resolved[text_key].present? && upload.present?
            raise Error, "Provide either pasted text or an uploaded file for #{human_side(text_key)}, not both."
          end

          resolved[text_key] = extract(upload) if upload.present?
        rescue SourceImports::Error, Error => error
          errors << (error.is_a?(SourceImports::Error) ? I18n.t("source_imports.errors.#{error.code}", default: error.message) : error.message)
        end
      end
      raise Error.new(errors.join(" "), resolved_attributes: resolved) if errors.any?

      resolved
    end

    private

    attr_reader :attributes

    def extract(upload)
      payload = SourceImports::UploadPayload.call(
        upload: upload,
        missing_message: "Choose a reference file to upload.",
        filename_fallback: "reference"
      )
      SourceImports::TextExtractor.call(
        format: payload.detection.format,
        bytes: payload.bytes
      )
    end

    def human_side(key)
      key == "source_text" ? "the source side" : "the approved translation side"
    end
  end
end
