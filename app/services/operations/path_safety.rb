module Operations
  module PathSafety
    class UnsafePath < StandardError; end

    DANGEROUS_ROOTS = [ Pathname.new("/") ].freeze

    module_function

    def prepare_root!(value, create: false, forbidden: [])
      path = absolute_path!(value)
      reject_dangerous!(path, forbidden: forbidden)
      reject_symlink_components!(path, allow_missing_leaf: create)
      FileUtils.mkdir_p(path, mode: 0o700) if create
      File.chmod(0o700, path) if create
      raise UnsafePath, "path must be a directory" unless path.directory?
      raise UnsafePath, "symbolic-link roots are not allowed" if path.symlink?

      path.realpath
    rescue Errno::ENOENT
      raise UnsafePath, "path does not exist"
    end

    def child!(root, relative)
      root = Pathname.new(root).realpath
      relative = Pathname.new(relative.to_s)
      raise UnsafePath, "relative path is required" if relative.absolute?
      raise UnsafePath, "path traversal is not allowed" if relative.each_filename.any? { |part| part == ".." }

      candidate = root.join(relative).cleanpath
      unless candidate == root || candidate.to_s.start_with?("#{root}#{File::SEPARATOR}")
        raise UnsafePath, "path escapes its root"
      end
      candidate
    end

    def reject_symlink_components!(path, allow_missing_leaf: false)
      current = Pathname.new(path.root? ? path.to_s : File::SEPARATOR)
      parts = path.each_filename.to_a
      parts.each_with_index do |part, index|
        current = current.join(part)
        next unless File.symlink?(current)

        raise UnsafePath, "symbolic-link path components are not allowed"
      rescue Errno::ENOENT
        next if allow_missing_leaf && index == parts.length - 1

        raise
      end
    end
    private_class_method :reject_symlink_components!

    def absolute_path!(value)
      string = value.to_s
      raise UnsafePath, "path is required" if string.strip.empty?

      path = Pathname.new(string)
      raise UnsafePath, "an absolute path is required" unless path.absolute?

      path.cleanpath
    end
    private_class_method :absolute_path!

    def reject_dangerous!(path, forbidden:)
      forbidden_paths = forbidden.compact.map { |entry| canonical_path(entry) }
      if DANGEROUS_ROOTS.include?(path) || forbidden_paths.any? { |root| contains_path?(root, path) }
        raise UnsafePath, "dangerous path is not allowed"
      end
    end
    private_class_method :reject_dangerous!

    def canonical_path(value)
      path = Pathname.new(value.to_s).expand_path.cleanpath
      path.realpath
    rescue Errno::ENOENT
      path
    end
    private_class_method :canonical_path

    def contains_path?(root, path)
      root_parts = root.each_filename.to_a
      path_parts = path.each_filename.to_a
      path_parts.first(root_parts.length) == root_parts
    end
    private_class_method :contains_path?
  end
end
