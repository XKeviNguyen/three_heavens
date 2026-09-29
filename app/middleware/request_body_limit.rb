class RequestBodyLimit
  MAX_FILE_UPLOAD_BYTES = 10 * 1024 * 1024
  MAX_FILES_PER_REQUEST = 2
  MULTIPART_OVERHEAD_BYTES = 1 * 1024 * 1024
  MAX_BYTES = (MAX_FILES_PER_REQUEST * MAX_FILE_UPLOAD_BYTES) + MULTIPART_OVERHEAD_BYTES
  PUBLIC_FORM_MAX_BYTES = 8 * 1024
  PUBLIC_FORM_PATHS = %w[/registration /confirmation_resend /email_confirmation /locale /appearance /auth/google/callback].freeze

  class ExceededError < StandardError; end

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
    limit = PUBLIC_FORM_PATHS.include?(environment["PATH_INFO"]) ? PUBLIC_FORM_MAX_BYTES : MAX_BYTES
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

  def payload_too_large
    [
      413,
      { "content-type" => "text/plain; charset=utf-8", "content-length" => "18", "cache-control" => "no-store" },
      [ "Payload too large\n" ]
    ]
  end
end
