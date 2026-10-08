require "rbconfig"

module SourceImports
  # Extracts text from an untrusted PDF in a separate child process whose
  # resources the kernel bounds, so a small hostile document (for example a
  # compressed stream that inflates to gigabytes) cannot grow the web process.
  #
  # The child is a fresh Ruby interpreter that loads only pdf-reader
  # (PdfExtractor::Worker). It receives no environment, credentials, or open
  # files other than two pipes, runs in its own process group, and is limited
  # to MEMORY_LIMIT_BYTES of address space and a few seconds of CPU; it cannot
  # write files or dump core. The parent streams the PDF to its standard input,
  # reads at most MAX_OUTPUT_BYTES back, and kills and reaps the whole group
  # when the wall-clock limit passes or the output grows too large.
  #
  # MEMORY_LIMIT_BYTES was chosen from measurements: representative text,
  # multilingual, 100-page, vector-heavy, and 9 MB image PDFs peak between 95
  # and 118 MB of address space (24 to 47 MB resident), while a 1 MB PDF that
  # inflates to 1 GiB previously grew the web process by about 850 MB and is
  # now stopped at about 150 MB resident in the worker.
  #
  # That bounds one worker; MAX_ACTIVE_WORKERS bounds them all. Puma runs a
  # single process (config/puma.rb refuses WEB_CONCURRENCY above 1), so
  # WORKER_SLOTS counts every PDF worker in the container. Measured in the
  # production image under a 768 MiB no-swap limit, with Solid Queue in Puma:
  # the container holds about 260 to 290 MiB idle and about 370 to 400 MiB
  # after serving uploads (about 320 MiB of it not reclaimable). One worker
  # at its full 256 MiB therefore stays below about 660 MiB; two could need
  # about 880 MiB. Without a limit, three simultaneous hostile PDFs drove the
  # container to its 768 MiB cap, where the kernel kills a process. Hence one
  # worker at a time.
  #
  # Parsing typical PDFs takes under a second, so a caller waits up to
  # ADMISSION_WAIT_SECONDS for the running worker and is otherwise told to
  # retry, holding a web thread for well under the parse time limit. A PDF
  # near the extracted character limit takes about 2.6 seconds, so of two
  # such uploads at the same moment one is asked to retry.
  class PdfExtractor
    MEMORY_LIMIT_BYTES = 256.megabytes
    MAX_OUTPUT_BYTES = (Limits::MAX_EXTRACTED_CHARACTERS * 4) + 64
    READ_CHUNK_BYTES = 64.kilobytes
    WORKER_PATH = File.expand_path("pdf_extractor/worker.rb", __dir__)
    MESSAGES = {
      "malformed_pdf" => "The selected PDF could not be read safely.",
      "pdf_busy" => "The server is busy processing other PDFs. Try again in a moment.",
      "pdf_encrypted" => "Encrypted or password-protected PDFs are not supported.",
      "pdf_no_text" => "This PDF does not contain extractable text. Scanned PDFs need OCR, which is not supported yet.",
      "pdf_timeout" => "This PDF took too long to process.",
      "pdf_too_many_pages" => "This PDF has too many pages to process safely.",
      "source_too_long" => "The extracted source exceeds the character limit."
    }.freeze
    # Text layout is CPU-bound Ruby, about 1.6 times faster with YJIT, which
    # production enables. A small code budget keeps its reserved address space
    # inside MEMORY_LIMIT_BYTES.
    JIT_ARGUMENTS = (defined?(RubyVM::YJIT) ? %w[--yjit --yjit-mem-size=16] : []).freeze
    # CPU-limit signals: SIGXCPU at the soft limit, SIGKILL at the hard limit.
    CPU_LIMIT_SIGNALS = [ Signal.list.fetch("XCPU"), Signal.list.fetch("KILL") ].freeze
    MAX_ACTIVE_WORKERS = 1
    ADMISSION_WAIT_SECONDS = 2
    WORKER_SLOTS = WorkerSlots.new(limit: MAX_ACTIVE_WORKERS, wait_seconds: ADMISSION_WAIT_SECONDS)

    def self.call(bytes, time_limit: Limits::MAX_PDF_PARSE_SECONDS, slots: WORKER_SLOTS)
      new(bytes, time_limit:, slots:).call
    end

    def initialize(bytes, time_limit:, slots: WORKER_SLOTS)
      @bytes = bytes.b
      @time_limit = time_limit
      @slots = slots
    end

    def call
      raise ArgumentError, "PDF exceeds the upload limit" if bytes.bytesize > Limits::MAX_UPLOAD_BYTES

      interpret(slots.hold { run_worker })
    end

    private

    attr_reader :bytes, :time_limit, :slots

    # Returns the worker's output and exit status, or :timeout or
    # :output_too_large after killing it.
    def run_worker
      deadline = monotonic_now + time_limit
      input_reader, input_writer = IO.pipe
      output_reader, output_writer = IO.pipe
      pid = Process.spawn({ "MALLOC_ARENA_MAX" => "2" }, *command,
                          in: input_reader, out: output_writer, err: File::NULL, **spawn_options)
      input_reader.close
      output_writer.close

      output = exchange(input_writer, output_reader, deadline)
      return output if output.is_a?(Symbol)

      status = wait_for_exit(pid, deadline)
      return :timeout unless status

      pid = nil
      [ output, status ]
    ensure
      [ input_reader, input_writer, output_reader, output_writer ].each { |io| io&.close unless io&.closed? }
      terminate(pid) if pid
    end

    # Writes the PDF and reads the result concurrently, so neither side can
    # block the other, and stops at the deadline or the output limit.
    def exchange(input, output, deadline)
      written = 0
      result = +"".b
      loop do
        remaining = deadline - monotonic_now
        return :timeout unless remaining.positive?

        readable, writable = IO.select([ output ], input.closed? ? [] : [ input ], nil, remaining)
        return :timeout unless readable || writable

        written = write_input(input, written) if writable&.any?
        next unless readable&.any?

        chunk = output.read_nonblock(READ_CHUNK_BYTES, exception: false)
        return result if chunk.nil?
        next if chunk == :wait_readable

        result << chunk
        return :output_too_large if result.bytesize > MAX_OUTPUT_BYTES
      end
    end

    def write_input(input, written)
      count = input.write_nonblock(bytes.byteslice(written, READ_CHUNK_BYTES), exception: false)
      written += count if count.is_a?(Integer)
      input.close if written >= bytes.bytesize
      written
    rescue Errno::EPIPE
      # The worker stopped reading; its exit status explains why.
      input.close
      written
    end

    def wait_for_exit(pid, deadline)
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return status if status
        return nil unless monotonic_now < deadline

        sleep 0.005
      end
    end

    # Kills the worker's whole process group before reaping it, so the group
    # id cannot have been reused, and always reaps so no zombie is left.
    def terminate(pid)
      Process.kill(:KILL, -pid)
    rescue Errno::ESRCH
      nil
    ensure
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end

    def interpret(result)
      failure!("pdf_timeout") if result == :timeout
      failure!("malformed_pdf") if result == :output_too_large

      output, status = result
      failure!("pdf_timeout") if status.signaled? && CPU_LIMIT_SIGNALS.include?(status.termsig)
      # Running out of memory, crashing, or any unexpected worker failure.
      failure!("malformed_pdf") unless status.success?

      header, text = output.split("\n", 2)
      if header == "ok" && text
        text.force_encoding(Encoding::UTF_8)
        failure!("malformed_pdf") unless text.valid_encoding?
        failure!("source_too_long") if text.length > Limits::MAX_EXTRACTED_CHARACTERS
        return text
      end
      code = header.to_s.delete_prefix("error ")
      failure!(MESSAGES.key?(code) ? code : "malformed_pdf")
    end

    def failure!(code)
      raise Error.new(code, MESSAGES.fetch(code))
    end

    def command
      [
        RbConfig.ruby, "--disable-all", *JIT_ARGUMENTS, *self.class.load_path_arguments, "-r", WORKER_PATH,
        "-e", "SourceImports::PdfExtractor::Worker.run",
        Limits::MAX_PDF_PAGES.to_s, Limits::MAX_EXTRACTED_CHARACTERS.to_s
      ]
    end

    def spawn_options
      cpu_seconds = time_limit.ceil
      {
        unsetenv_others: true, close_others: true, pgroup: true, chdir: "/", umask: 0o077,
        rlimit_as: MEMORY_LIMIT_BYTES, rlimit_cpu: [ cpu_seconds, cpu_seconds + 1 ],
        rlimit_core: 0, rlimit_fsize: 0, rlimit_nofile: 16
      }
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # The worker runs without RubyGems or Bundler, so it receives the load
    # paths of pdf-reader and its runtime dependencies from the bundle.
    def self.load_path_arguments
      @load_path_arguments ||= begin
        paths = []
        pending = [ "pdf-reader" ]
        seen = {}
        until pending.empty?
          name = pending.shift
          next if seen[name]

          spec = seen[name] = Gem.loaded_specs.fetch(name)
          paths.concat(spec.full_require_paths)
          pending.concat(spec.runtime_dependencies.map(&:name))
        end
        paths.uniq.flat_map { |path| [ "-I", path ] }.freeze
      end
    end
  end
end
