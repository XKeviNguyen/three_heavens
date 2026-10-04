require "strscan"
require "rack/multipart"

class RequestBodyLimit
  MAX_FILE_UPLOAD_BYTES = 10 * 1024 * 1024
  MAX_FILES_PER_REQUEST = 2
  MULTIPART_OVERHEAD_BYTES = 1 * 1024 * 1024
  MAX_BYTES = (MAX_FILES_PER_REQUEST * MAX_FILE_UPLOAD_BYTES) + MULTIPART_OVERHEAD_BYTES
  PUBLIC_FORM_MAX_BYTES = 8 * 1024
  PUBLIC_FORM_PATHS = %w[/session /registration /confirmation_resend /email_confirmation /locale /appearance /auth/google/callback /auth/google/ceremony].freeze

  # Rails parses a form body (multipart into tempfiles) for any route before
  # authentication runs, so a body is held to the smallest limit its route
  # needs. Every request gets DEFAULT_MAX_BYTES unless its routed path is one
  # of the explicit exceptions below, and only for the methods that submit
  # forms (POST, and PATCH/PUT before Rack::MethodOverride runs).
  DEFAULT_MAX_BYTES = 64 * 1024
  BODY_METHODS = %w[POST PATCH PUT].freeze
  # Forms whose fields may each hold a whole document (100,000 characters,
  # up to 12 bytes each once UTF-8 and percent-encoded) or a 100-entry
  # glossary.
  LONG_TEXT_MAX_BYTES = 2 * 1024 * 1024
  LONG_TEXT_PATHS = [
    %r{\A/translation_workspace(?:/options)?\z},
    %r{\A/final_translations/[^/]+/save_revision\z},
    %r{\A/(?:glossaries|methodology_profiles)(?:/[^/]+)?\z},
    %r{\A/workspace_terminology\z}
  ].freeze
  # The only forms that carry files: up to MAX_FILES_PER_REQUEST uploads.
  UPLOAD_PATHS = [
    %r{\A/source_imports\z},
    %r{\A/translation_references(?:/[^/]+)?\z}
  ].freeze

  # Rails parses a JSON body into parameters for every action before any
  # callback runs (the request log records them), so JSON is bounded here for
  # signed-out requests too. Parsed JSON takes over a hundred times its size
  # in memory, so its byte limit follows the largest legitimate JSON request
  # instead of the multipart upload limit: the workspace draft autosave, whose
  # payload TranslationWorkspaceDraft::MAX_PAYLOAD_BYTES bounds, plus envelope
  # and headroom. Every other JSON request is a small browser call.
  JSON_MAX_BYTES = 8 * 1024
  JSON_PATH_MAX_BYTES = { "/translation_workspace_draft" => 512 * 1024 }.freeze
  # A JSON body within its byte limit can still describe hundreds of thousands
  # of empty objects or arrays. Legitimate bodies hold well under two hundred
  # strings, containers, and separators, so larger structures are rejected
  # before JSON.parse allocates them.
  JSON_MAX_TOKENS = 1_000

  class ExceededError < StandardError; end

  # Rack::MethodOverride parses form bodies outside Rails' exception
  # handling, so a body over one of Rack's multipart limits (non-file field
  # bytes, parts, files) would otherwise reach Puma as a 500.
  MULTIPART_LIMIT_ERRORS = [
    Rack::Multipart::BoundaryTooLongError,
    Rack::Multipart::MultipartPartLimitError,
    Rack::Multipart::MultipartTotalPartLimitError
  ].freeze

  JSON_STRING = /"(?:[^"\\]++|\\.)*+"/m
  JSON_UNCOUNTED = /[^"\[{,]+/
  JSON_COUNTED = /[\[{,]/

  # Registered as the JSON parameter parser in config/initializers/json_parameters.rb.
  # Any error here becomes a 400 Bad Request (ActionDispatch::Http::Parameters::ParseError).
  JSON_PARAMETER_PARSER = lambda do |raw_post|
    raise ArgumentError, "JSON request body is too complex" unless json_within_token_limit?(raw_post)

    data = ActiveSupport::JSON.decode(raw_post)
    data.is_a?(Hash) ? data : { _json: data }
  end

  # Counts strings, containers, and separators in one linear pass; the
  # possessive quantifiers never backtrack. An unterminated string is
  # malformed JSON and fails the check.
  def self.json_within_token_limit?(json, limit = JSON_MAX_TOKENS)
    scanner = StringScanner.new(json)
    tokens = 0
    until scanner.eos?
      next if scanner.skip(JSON_UNCOUNTED)
      return false if (tokens += 1) > limit
      return false unless scanner.skip(JSON_STRING) || scanner.skip(JSON_COUNTED)
    end
    true
  end

  class LimitedInput
    READ_CHUNK_BYTES = 64 * 1024

    def initialize(input, limit)
      @input = input
      @limit = limit
      @read_bytes = 0
    end

    def read(length = nil, buffer = nil)
      return account(@input.read(length, buffer)) if length

      remaining = @limit - @read_bytes
      data = @input.read(remaining + 1)
      raise ExceededError, "Request body exceeds #{@limit} bytes" if data && data.bytesize > remaining

      @read_bytes += data.bytesize if data
      buffer ? buffer.replace(data.to_s) : data
    end

    def gets(*arguments)
      account(@input.gets(*arguments))
    end

    def each
      return enum_for(:each) unless block_given?

      while (chunk = read(READ_CHUNK_BYTES))
        yield chunk
      end
      self
    end

    def rewind
      @input.rewind
      0
    end

    def size
      @input.respond_to?(:size) ? @input.size : nil
    end

    def eof?
      @input.eof?
    end

    def close
      @input.close if @input.respond_to?(:close)
    end

    def closed?
      @input.respond_to?(:closed?) ? @input.closed? : false
    end

    def binmode
      @input.binmode if @input.respond_to?(:binmode)
      self
    end

    def flush
      @input.flush if @input.respond_to?(:flush)
      self
    end

    def set_encoding(*arguments)
      @input.set_encoding(*arguments) if @input.respond_to?(:set_encoding)
      self
    end

    private

    def account(data)
      @read_bytes += data.bytesize if data
      raise ExceededError, "Request body exceeds #{@limit} bytes" if @read_bytes > @limit

      data
    end
  end

  def initialize(app)
    @app = app
  end

  def call(environment)
    limit = limit_for(environment)
    length = Integer(environment["CONTENT_LENGTH"], 10, exception: false)
    return payload_too_large if length && length > limit
    return app.call(environment) if length

    input = environment["rack.input"]
    return app.call(environment) unless input

    environment["rack.input"] = LimitedInput.new(input, limit) unless input.is_a?(LimitedInput)
    app.call(environment)
  rescue ExceededError
    payload_too_large
  rescue *MULTIPART_LIMIT_ERRORS
    bad_request
  end

  private

  attr_reader :app

  def limit_for(environment)
    path = routed_path(environment["PATH_INFO"])
    return JSON_PATH_MAX_BYTES.fetch(path, JSON_MAX_BYTES) if parsed_as_parameters?(environment)
    return PUBLIC_FORM_MAX_BYTES if PUBLIC_FORM_PATHS.include?(path)
    return DEFAULT_MAX_BYTES unless BODY_METHODS.include?(environment["REQUEST_METHOD"])
    return MAX_BYTES if UPLOAD_PATHS.any? { |pattern| pattern.match?(path) }
    return LONG_TEXT_MAX_BYTES if LONG_TEXT_PATHS.any? { |pattern| pattern.match?(path) }

    DEFAULT_MAX_BYTES
  end

  # The path the router matches: it squeezes repeated slashes and ignores a
  # trailing slash, and every route accepts an optional ".format" suffix.
  def routed_path(path)
    path.to_s.squeeze("/").sub(%r{(?<=.)/\z}, "").sub(%r{\.[^./]*\z}, "")
  end

  # True for exactly the content types Rails hands to a registered parameter
  # parser (JSON by default), resolved the way ActionDispatch::Request does.
  def parsed_as_parameters?(environment)
    media_type = environment["CONTENT_TYPE"].to_s[/\A[^,;]*/].strip.downcase
    return false if media_type.empty?

    symbol = Mime::Type.lookup(media_type).symbol
    symbol.present? && ActionDispatch::Request.parameter_parsers.key?(symbol)
  rescue Mime::Type::InvalidMimeType
    false
  end

  def bad_request
    [
      400,
      { "content-type" => "text/plain; charset=utf-8", "content-length" => "12", "cache-control" => "no-store" },
      [ "Bad request\n" ]
    ]
  end

  def payload_too_large
    [
      413,
      { "content-type" => "text/plain; charset=utf-8", "content-length" => "18", "cache-control" => "no-store" },
      [ "Payload too large\n" ]
    ]
  end
end
