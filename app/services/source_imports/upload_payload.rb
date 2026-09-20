module SourceImports
  class UploadPayload
    Result = Data.define(:bytes, :filename, :detection)

    def self.call(upload:, missing_message: "Choose a source file to upload.", filename_fallback: "source")
      new(upload:, missing_message:, filename_fallback:).call
    end

    def initialize(upload:, missing_message:, filename_fallback:)
      @upload = upload
      @missing_message = missing_message
      @filename_fallback = filename_fallback
    end

    def call
      raise Error.new("missing_file", missing_message) unless upload.respond_to?(:read)

      advertised_size = upload.respond_to?(:size) ? upload.size : nil
      reject_oversize! if advertised_size && advertised_size > Limits::MAX_UPLOAD_BYTES

      upload.rewind if upload.respond_to?(:rewind)
      bytes = upload.read(Limits::MAX_UPLOAD_BYTES + 1).to_s.b
      reject_oversize! if bytes.bytesize > Limits::MAX_UPLOAD_BYTES
      filename = Filename.safe_original(upload.original_filename, fallback: filename_fallback)
      Result.new(
        bytes:,
        filename:,
        detection: Detector.call(
          filename:,
          bytes:,
          declared_content_type: upload.respond_to?(:content_type) ? upload.content_type : nil
        )
      )
    ensure
      upload.rewind if upload.respond_to?(:rewind)
    end

    private

    attr_reader :filename_fallback, :missing_message, :upload

    def reject_oversize!
      raise Error.new(
        "file_too_large",
        "The source file is larger than the #{Limits::MAX_UPLOAD_BYTES / 1.megabyte} MiB limit."
      )
    end
  end
end
