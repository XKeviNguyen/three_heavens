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
    Ai::OpenRouterClient.new(api_key: "test-truncated-output-key", http_factory: ->(_uri) { Http.new(response) })
  end
end
