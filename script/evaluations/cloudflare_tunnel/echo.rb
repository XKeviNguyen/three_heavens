# Stands in for Puma behind Thruster: answers every request with the
# REMOTE_ADDR and forwarding headers exactly as they arrive at port 3000.
require "json"
require "socket"

server = TCPServer.new("0.0.0.0", 3000)
loop do
  client = server.accept
  headers = {}
  request_line = client.gets.to_s
  while (line = client.gets) && line != "\r\n"
    name, value = line.split(":", 2)
    headers[name.strip.downcase] = value.to_s.strip
  end
  body = JSON.generate(
    "request" => request_line.strip, "remote_addr" => client.peeraddr(false)[3],
    "headers" => headers.select { |key, _| key.match?(/forwarded|client-ip|connecting-ip|true-client/) }
  )
  client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  client.close
rescue StandardError
  client&.close
end
