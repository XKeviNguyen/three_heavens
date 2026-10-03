module SourceImports
  module Limits
    FORMATS = %w[txt md docx pdf].freeze
    EXTENSIONS = FORMATS.to_h { |format| [ ".#{format}", format ] }.freeze
    MAX_UPLOAD_BYTES = 10.megabytes
    MAX_ORIGINAL_FILENAME_CHARACTERS = 255
    MAX_EXTRACTED_CHARACTERS = Ai::UsageLimits::MAX_SOURCE_CHARACTERS
    MAX_PDF_PAGES = 100
    MAX_PDF_PARSE_SECONDS = 5
    BUSY_RETRY_AFTER_SECONDS = 5
    # Every upload is extracted here and all PDFs share one worker slot, so
    # each account has one budget of file-carrying requests across the
    # upload forms. A translation reference request can carry two PDFs, so
    # at the 5-second parse limit 10 requests hold the slot for at most a
    # third of the window.
    UPLOADS_PER_WINDOW = 10
    UPLOAD_WINDOW = 5.minutes
    UPLOAD_RATE_LIMIT_SCOPE = "uploads"
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
    EXTRACTION_VERSION = "document-io-v3"
    REQUEST_KEY_FORMAT = /\A[0-9a-f]{32}\z/
    # How long a duplicate delivery waits for the first delivery of the same
    # upload action to reach its final outcome.
    REQUEST_LOCK_WAIT_SECONDS = 30
  end
end
