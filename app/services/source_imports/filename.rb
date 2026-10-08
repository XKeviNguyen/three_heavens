module SourceImports
  module Filename
    module_function

    def safe_original(value, fallback: "source")
      # File.basename raises on NUL, which a multipart filename can carry.
      basename = File.basename(value.to_s.delete("\0").tr("\\", "/"))
      sanitized = ActiveStorage::Filename.new(basename).sanitized
      sanitized = sanitized.delete("\r\n\0").strip
      truncate_preserving_extension(sanitized.presence || fallback)
    end

    def export(title, suffix:, extension:)
      stem = title.to_s.unicode_normalize(:nfkc)
                  .gsub(/[\r\n\0]/, "")
                  .gsub(/[^\p{Alnum}\p{L}\p{M}._-]+/u, "-")
                  .gsub(/\A[-.]+|[-.]+\z/, "")
                  .first(120)
                  .presence || "translation"
      "#{stem}-#{suffix}.#{extension}"
    end

    def truncate_preserving_extension(filename)
      maximum = Limits::MAX_ORIGINAL_FILENAME_CHARACTERS
      return filename if filename.length <= maximum

      extension = File.extname(filename)
      return filename.first(maximum) if extension.empty? || extension.length >= maximum

      stem = filename.delete_suffix(extension).first(maximum - extension.length)
      "#{stem}#{extension}"
    end
    private_class_method :truncate_preserving_extension
  end
end
