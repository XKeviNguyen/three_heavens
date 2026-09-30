require "strscan"

class RequestBodyLimit
  MAX_FILE_UPLOAD_BYTES = 10 * 1024 * 1024
  MAX_FILES_PER_REQUEST = 2
  MULTIPART_OVERHEAD_BYTES = 1 * 1024 * 1024
  MAX_BYTES = (MAX_FILES_PER_REQUEST * MAX_FILE_UPLOAD_BYTES) + MULTIPART_OVERHEAD_BYTES
  PUBLIC_FORM_MAX_BYTES = 8 * 1024
  PUBLIC_FORM_PATHS = %w[/registration /confirmation_resend /email_confirmation /locale /appearance /auth/google/callback /auth/google/ceremony].freeze

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
  end

  private

  attr_reader :app

  def limit_for(environment)
    path = environment["PATH_INFO"]
    return JSON_PATH_MAX_BYTES.fetch(path, JSON_MAX_BYTES) if parsed_as_parameters?(environment)

    PUBLIC_FORM_PATHS.include?(path) ? PUBLIC_FORM_MAX_BYTES : MAX_BYTES
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

  def payload_too_large
    [
      413,
      { "content-type" => "text/plain; charset=utf-8", "content-length" => "18", "cache-control" => "no-store" },
      [ "Payload too large\n" ]
    ]
  end
end
