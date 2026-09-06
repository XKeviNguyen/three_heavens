module TranslationReferences
  class AuthoringAttributes
    class Error < StandardError; end

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
      SIDES.each do |text_key, file_key|
        pasted = attributes[text_key].to_s
        upload = attributes[file_key]
        if pasted.present? && upload.present?
          raise Error, "Provide either pasted text or an uploaded file for #{human_side(text_key)}, not both."
        end

        resolved[text_key] = upload.present? ? extract(upload) : pasted
      end
      resolved
    rescue SourceImports::Error => error
      raise Error, error.message
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
