module SourceImports
  class Error < StandardError
    attr_reader :code, :source_import

    def initialize(code, message, source_import: nil)
      @code = code
      @source_import = source_import
      super(message)
    end
  end
end
