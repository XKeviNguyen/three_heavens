module TruncatedOpenRouterClientHelper
  Response = Data.define(:code, :body)

  class Http
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

    def initialize(response)
      @response = response
    end

    def start
      yield self
    end

    def request(_request)
      @response
    end
  end

  def truncated_open_router_client(content)
    response = Response.new(
      code: "200",
      body: JSON.generate(
        choices: [
          { finish_reason: "length", message: { content: content } }
        ]
      )
    )
    original_api_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "test-truncated-output-key"
    Ai::OpenRouterClient.new(http_factory: ->(_uri) { Http.new(response) })
  ensure
    if original_api_key
      ENV["OPENROUTER_API_KEY"] = original_api_key
    else
      ENV.delete("OPENROUTER_API_KEY")
    end
  end
end
