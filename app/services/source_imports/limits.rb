module SourceImports
  module Limits
    FORMATS = %w[txt md docx].freeze
    EXTENSIONS = FORMATS.to_h { |format| [ ".#{format}", format ] }.freeze
    MAX_UPLOAD_BYTES = 10.megabytes
    MAX_ORIGINAL_FILENAME_CHARACTERS = 255
    MAX_EXTRACTED_CHARACTERS = Ai::UsageLimits::MAX_SOURCE_CHARACTERS
    MAX_DOCX_ENTRIES = 500
    MAX_DOCX_UNCOMPRESSED_BYTES = 50.megabytes
    MAX_DOCUMENT_XML_BYTES = 8.megabytes
    MAX_SECONDARY_XML_BYTES = 2.megabytes
    MAX_RELATIONSHIPS_XML_BYTES = 1.megabyte
    MAX_CONTENT_TYPES_BYTES = 1.megabyte
    MAX_RELEVANT_XML_BYTES = 16.megabytes
    MAX_COMPRESSION_RATIO = 100
    COMPRESSION_RATIO_MINIMUM_BYTES = 1.megabyte
    MAX_DOCX_STRUCTURE_DEPTH = 16
    IMPORT_EXPIRATION = 24.hours
    CLEANUP_BATCH_SIZE = 100
    EXTRACTION_VERSION = "document-io-v2"
  end
end
