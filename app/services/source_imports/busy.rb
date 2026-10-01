module SourceImports
  # The server cannot process this upload right now. Nothing was stored, so
  # the same upload action can be retried and is processed afresh.
  class Busy < Error; end
end
