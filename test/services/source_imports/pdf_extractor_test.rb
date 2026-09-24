require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class PdfExtractorTest < ActiveSupport::TestCase
    include DocumentIoTestHelper
    test "detects and extracts bounded text PDF without a provider call" do
      bytes = pdf_with_text("Hello translation")
      detected = Detector.call(filename: "source.pdf", bytes: bytes, declared_content_type: "application/pdf")
      assert_equal "pdf", detected.format
      assert_equal "application/pdf", detected.content_type
      assert_includes TextExtractor.call(format: "pdf", bytes: bytes), "Hello translation"
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

    test "rejects image-only or malformed PDF without empty source" do
      assert_equal "pdf_no_text", assert_raises(Error) {
        TextExtractor.call(format: "pdf", bytes: pdf_with_text(""))
      }.code
      assert_equal "malformed_pdf", assert_raises(Error) {
        PdfExtractor.call("%PDF-1.4\nnot a document")
      }.code
    end

    test "rejects encrypted PDF before reading text" do
      encrypted = Rails.root.join("test/fixtures/files/encrypted_source.pdf").binread
      assert_equal "pdf_encrypted", assert_raises(Error) { PdfExtractor.call(encrypted) }.code
      fake_reader = Struct.new(:objects).new(Struct.new(:encrypted?).new(true))
      with_stubbed_method(PDF::Reader, :new, ->(*) { fake_reader }) do
        assert_equal "pdf_encrypted", assert_raises(Error) { PdfExtractor.call(pdf_with_text("Hello")) }.code
      end
      with_stubbed_method(PDF::Reader, :new, ->(*) { raise PDF::Reader::EncryptedPDFError }) do
        assert_equal "pdf_encrypted", assert_raises(Error) { PdfExtractor.call(pdf_with_text("Hello")) }.code
      end
    end

    test "bounds pages extracted characters and parser time" do
      fake_page = Struct.new(:text).new("text")
      fake_reader = Struct.new(:page_count, :pages, :objects).new(Limits::MAX_PDF_PAGES + 1, [ fake_page ], Struct.new(:encrypted?).new(false))
      with_stubbed_method(PDF::Reader, :new, ->(*) { fake_reader }) do
        assert_equal "pdf_too_many_pages", assert_raises(Error) { PdfExtractor.call(pdf_with_text("Hello")) }.code
      end
      fake_reader.page_count = 1
      fake_reader.pages = [ Struct.new(:text).new("x" * (Limits::MAX_EXTRACTED_CHARACTERS + 1)) ]
      with_stubbed_method(PDF::Reader, :new, ->(*) { fake_reader }) do
        assert_equal "source_too_long", assert_raises(Error) { PdfExtractor.call(pdf_with_text("Hello")) }.code
      end
      with_stubbed_method(Timeout, :timeout, ->(*) { raise Timeout::Error }) do
        assert_equal "pdf_timeout", assert_raises(Error) { PdfExtractor.call(pdf_with_text("Hello")) }.code
      end
    end

    private

    def with_stubbed_method(receiver, name, replacement)
      original = receiver.method(name)
      receiver.define_singleton_method(name, replacement)
      yield
    ensure
      receiver.define_singleton_method(name, original)
    end
  end
end
