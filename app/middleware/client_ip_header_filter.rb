# kamal-proxy and Thruster report the client only by appending to
# X-Forwarded-For, so a Client-Ip header always comes from the client itself.
# Removed before ActionDispatch::RemoteIp sees it, it can neither choose
# request.remote_ip nor, by disagreeing with X-Forwarded-For, raise
# IpSpoofAttackError while the request is logged, outside any error handling.
class ClientIpHeaderFilter
  def initialize(app)
    @app = app
  end

  def call(environment)
    environment.delete("HTTP_CLIENT_IP")
    @app.call(environment)
  end
end
