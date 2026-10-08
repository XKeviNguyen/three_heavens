# Validates post-action return destinations. Only same-origin absolute paths
# to a GET route are accepted; anything a browser could resolve to another
# host (scheme-relative, backslash, scheme, control characters) is refused.
module SafeReturnPath
  MAXIMUM_LENGTH = 512

  def self.call(path)
    path = path.to_s
    return if path.empty? || path.length > MAXIMUM_LENGTH
    return unless path.start_with?("/") && !path.start_with?("//") && path.match?(/\A[\x21-\x7e]+\z/)
    return if path.include?("\\")

    uri = URI.parse(path)
    return unless uri.scheme.nil? && uri.host.nil?

    Rails.application.routes.recognize_path(uri.path, method: :get)
    path
  rescue URI::InvalidURIError, ActionController::RoutingError
    nil
  end
end
