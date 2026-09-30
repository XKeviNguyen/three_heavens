# Parse JSON request parameters only after bounding their structure; see
# RequestBodyLimit::JSON_MAX_TOKENS.
ActionDispatch::Request.parameter_parsers =
  ActionDispatch::Request.parameter_parsers.merge(json: RequestBodyLimit::JSON_PARAMETER_PARSER)
