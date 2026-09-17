class RequestBodyLimit
  MAX_BYTES = 12 * 1024 * 1024

  def initialize(app)
    @app = app
  end

  def call(environment)
    length = Integer(environment["CONTENT_LENGTH"], 10, exception: false)
    return payload_too_large if length && length > MAX_BYTES

    @app.call(environment)
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
