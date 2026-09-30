require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class PdfExtractorTest < ActiveSupport::TestCase
    include DocumentIoTestHelper

    # A fake worker program, to exercise the parent side of the process
    # boundary with outcomes a real PDF cannot produce on demand.
    def self.fake_extractor(program)
      Class.new(PdfExtractor) do
        define_method(:command) { [ RbConfig.ruby, "--disable-all", "-e", program ] }
      end
    end

    setup { @children_before = child_process_ids }

    teardown do
      assert_empty child_process_ids - @children_before, "the extractor left a child process behind"
    end

    test "detects and extracts bounded text PDF without a provider call" do
      bytes = pdf_with_text("Hello translation")
      detected = Detector.call(filename: "source.pdf", bytes: bytes, declared_content_type: "application/pdf")
      assert_equal "pdf", detected.format
      assert_equal "application/pdf", detected.content_type
      assert_includes TextExtractor.call(format: "pdf", bytes: bytes), "Hello translation"
    end

    test "extracts every page of a multi-page PDF in order" do
      text = PdfExtractor.call(pdf_with_pages([ "First page", "Second page", "Third page" ]))

      assert_match(/First page.*\n\n.*Second page.*\n\n.*Third page/m, text)
    end

    test "preserves Japanese and Vietnamese from a text PDF" do
      bytes = Rails.root.join("test/fixtures/files/multilingual_source.pdf").binread
      text = TextExtractor.call(format: "pdf", bytes: bytes)
      assert_includes text, "日本語の文章"
      assert_includes text, "Tiếng Việt có dấu"
    end

    test "rejects mismatched PDF extension MIME and signature" do
      bytes = pdf_with_text("Hello")
      assert_equal "mismatched_type", assert_raises(Error) {
        Detector.call(filename: "source.pdf", bytes: "not a pdf", declared_content_type: "application/pdf")
      }.code
      assert_equal "mismatched_type", assert_raises(Error) {
        Detector.call(filename: "source.pdf", bytes: bytes, declared_content_type: "text/plain")
      }.code
      assert_equal "mismatched_type", assert_raises(Error) {
        Detector.call(filename: "source.pdf", bytes: bytes)
      }.code
      assert_equal "mismatched_type", assert_raises(Error) {
        Detector.call(filename: "source.txt", bytes: bytes, declared_content_type: "text/plain")
      }.code
    end

    test "rejects image-only, empty, or malformed PDF without empty source" do
      assert_equal "pdf_no_text", assert_raises(Error) { TextExtractor.call(format: "pdf", bytes: image_only_pdf) }.code
      assert_equal "pdf_no_text", assert_raises(Error) { TextExtractor.call(format: "pdf", bytes: pdf_with_text("")) }.code
      assert_equal "malformed_pdf", assert_raises(Error) { PdfExtractor.call("%PDF-1.4\nnot a document") }.code
      assert_equal "malformed_pdf", assert_raises(Error) { PdfExtractor.call(pdf_with_text("Hello").byteslice(0, 200)) }.code
    end

    test "rejects encrypted PDF before reading text" do
      encrypted = Rails.root.join("test/fixtures/files/encrypted_source.pdf").binread
      assert_equal "pdf_encrypted", assert_raises(Error) { PdfExtractor.call(encrypted) }.code
    end

    test "bounds pages and extracted characters" do
      too_many_pages = pdf_with_pages(Array.new(Limits::MAX_PDF_PAGES + 1) { |index| "Page #{index}" })
      assert_equal "pdf_too_many_pages", assert_raises(Error) { PdfExtractor.call(too_many_pages) }.code

      # Text is laid out within the page, so a dense page holds about 10,000
      # characters. Laying out 100,000 characters takes seconds, so this case
      # gets a generous time limit and tests only the character limit.
      dense_page = (1..50).map { |line| "BT /F1 3 Tf 10 #{780 - line * 5} Td (#{'Word ' * 40}#{line}) Tj ET" }.join("\n")
      too_long = build_pdf(Array.new(11) { { content: dense_page } })
      assert_equal "source_too_long", assert_raises(Error) { PdfExtractor.call(too_long, time_limit: 30) }.code
    end

    test "stops a PDF that takes too long and reaps the worker" do
      started = monotonic_now

      error = assert_raises(Error) { PdfExtractor.call(inflating_pdf(64.megabytes), time_limit: 1) }

      assert_equal "pdf_timeout", error.code
      assert_operator monotonic_now - started, :<, 3
    end

    # About 1 MB that inflates to 1 GiB. Parsed in the web process, this grew
    # it by roughly 850 MB; the worker's address-space limit stops it instead.
    test "a PDF that inflates beyond the memory limit fails safely without growing this process" do
      bomb = inflating_pdf(1.gigabyte)
      assert_operator bomb.bytesize, :<, 2.megabytes
      resident_before = resident_megabytes

      3.times do
        assert_equal "malformed_pdf", assert_raises(Error) { PdfExtractor.call(bomb) }.code
      end

      assert_operator resident_megabytes - resident_before, :<, 64
    end

    test "concurrent hostile PDFs are each contained" do
      bomb = inflating_pdf(1.gigabyte)
      resident_before = resident_megabytes

      codes = 2.times.map { Thread.new { assert_raises(Error) { PdfExtractor.call(bomb) }.code } }.map(&:value)

      assert_equal [ "malformed_pdf", "malformed_pdf" ], codes
      assert_operator resident_megabytes - resident_before, :<, 64
    end

    test "the worker gets no environment and runs under kernel resource limits" do
      extractor = PdfExtractor.new(pdf_with_text("Hello"), time_limit: 5)
      options = extractor.send(:spawn_options)

      assert_equal PdfExtractor::MEMORY_LIMIT_BYTES, options.fetch(:rlimit_as)
      assert_equal [ 5, 6 ], options.fetch(:rlimit_cpu)
      assert_equal [ 0, 0, 16 ], options.values_at(:rlimit_core, :rlimit_fsize, :rlimit_nofile)
      assert options.values_at(:unsetenv_others, :close_others, :pgroup).all?(true)
      probe = self.class.fake_extractor("STDOUT.write(%(ok\\n) + ENV.keys.sort.join(%(,)))")
      assert_equal "MALLOC_ARENA_MAX", probe.call(pdf_with_text("Hello"))
    end

    test "the extractor rejects input beyond the upload limit without starting a worker" do
      assert_raises(ArgumentError) { PdfExtractor.call("%PDF-".b + ("a" * Limits::MAX_UPLOAD_BYTES)) }
    end

    test "worker output beyond the limit, crashes, and unknown results are unreadable PDFs" do
      {
        "STDOUT.write(%(ok\\n) + (%(x) * #{PdfExtractor::MAX_OUTPUT_BYTES}))" => "malformed_pdf",
        "STDOUT.write(%(ok\\n) + %(\\xFF\\xFE))" => "malformed_pdf",
        "STDOUT.write(%(error pdf_timeout\\n)); exit! 3" => "malformed_pdf",
        "STDOUT.write(%(error something_else\\n))" => "malformed_pdf",
        "raise NoMemoryError" => "malformed_pdf",
        "STDOUT.write(%(error pdf_encrypted\\n))" => "pdf_encrypted"
      }.each do |program, code|
        assert_equal code, assert_raises(Error) { self.class.fake_extractor(program).call(pdf_with_text("Hello")) }.code, program
      end
    end

    test "a timed-out worker's whole process group is killed" do
      marker = "31.#{SecureRandom.random_number(10**6)}"
      program = "Process.spawn(%(/bin/sleep), %(#{marker})); sleep 30"

      assert_equal "pdf_timeout", assert_raises(Error) {
        self.class.fake_extractor(program).call(pdf_with_text("Hello"), time_limit: 1)
      }.code

      assert wait_until { processes_with_argument(marker).empty? }, "the worker's own child survived"
    end

    private

    def child_process_ids
      Dir.glob("/proc/[0-9]*/stat").filter_map do |path|
        parent_id = File.read(path).rpartition(") ").last.split[1].to_i
        File.basename(File.dirname(path)).to_i if parent_id == Process.pid
      rescue Errno::ENOENT, Errno::ESRCH
        nil
      end
    end

    def processes_with_argument(argument)
      Dir.glob("/proc/[0-9]*/cmdline").select do |path|
        File.read(path).split("\0").include?(argument)
      rescue Errno::ENOENT, Errno::ESRCH
        false
      end
    end

    def wait_until(seconds = 3)
      deadline = monotonic_now + seconds
      until yield
        return false if monotonic_now > deadline

        sleep 0.05
      end
      true
    end

    def resident_megabytes
      File.read("/proc/self/status")[/^VmRSS:\s+(\d+)/, 1].to_i / 1024
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
