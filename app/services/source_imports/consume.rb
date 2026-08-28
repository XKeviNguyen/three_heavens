module SourceImports
  class Consume
    def self.apply!(source_import:, document:, at: Time.current)
      new(source_import:, document:, at:).apply!
    end

    def self.finish!(source_import:, document:)
      source_import.update!(
        status: :consumed,
        consumed_at: Time.current,
        resulting_document: document,
        extracted_text: nil,
        failure_code: nil,
        failure_message: nil
      )
    end

    def initialize(source_import:, document:, at:)
      @source_import = source_import
      @document = document
      @at = at
    end

    def apply!
      unless source_import.available?(at:)
        raise Error.new("already_consumed", "This source import is no longer available.")
      end

      document.assign_attributes(
        source_kind: :uploaded_file,
        source_format: source_import.imported_format,
        original_filename: source_import.original_filename,
        detected_content_type: source_import.detected_content_type,
        original_byte_size: source_import.byte_size,
        source_sha256: source_import.sha256,
        extraction_version: source_import.extraction_version
      )
      document.source_file.attach(source_import.source_file.blob)
      document
    end

    private

    attr_reader :source_import, :document, :at
  end
end
