require "test_helper"
require_relative "../../support/document_io_test_helper"

module SourceImports
  class ExtractionTest < ActiveSupport::TestCase
    include DocumentIoTestHelper

    test "normalizes UTF-8 BOM and line endings without changing Unicode punctuation" do
      text = TextNormalizer.call("\xEF\xBB\xBF信仰—Đức tin\r\n次\r行".b)

      assert_equal "信仰—Đức tin\n次\n行", text
      assert_equal Encoding::UTF_8, text.encoding
    end

    test "rejects invalid UTF-8 NUL binary empty and over-limit text" do
      cases = {
        "invalid_utf8" => "\xFF".b,
        "binary_source" => "abc\0def".b,
        "empty_source" => " \n\t",
        "source_too_long" => "a" * (Limits::MAX_EXTRACTED_CHARACTERS + 1)
      }

      cases.each do |code, bytes|
        error = assert_raises(Error) { TextNormalizer.call(bytes) }
        assert_equal code, error.code
      end
    end

    test "removes a small number of unsafe controls and preserves tabs and newlines" do
      assert_equal "a\tb\nc", TextNormalizer.call("a\tb\u0001\nc")
    end

    test "detects only explicit supported extensions with matching content" do
      assert_equal "txt", Detector.call(filename: "source.TXT", bytes: "text").format
      assert_equal "md", Detector.call(filename: "source.md", bytes: "# text").format
      assert_equal "md", Detector.call(filename: "source.md", bytes: "<script>alert('source')</script>").format
      assert_equal "docx", Detector.call(filename: "source.docx", bytes: build_docx).format

      assert_equal "unsupported_format", assert_raises(Error) {
        Detector.call(filename: "source.pdf", bytes: "%PDF")
      }.code
      assert_equal "mismatched_type", assert_raises(Error) {
        Detector.call(filename: "source.txt", bytes: build_docx)
      }.code
      assert_equal "empty_source", assert_raises(Error) {
        TextExtractor.call(format: Detector.call(filename: "empty.txt", bytes: "").format, bytes: "")
      }.code
    end

    test "extracts DOCX paragraphs tabs breaks tables Unicode entities and skips deleted text" do
      xml = basic_document_xml(<<~XML)
        <w:p><w:r><w:t>Japanese 日本語 &amp; Vietnamese tiếng Việt</w:t><w:tab/><w:t>tabbed</w:t><w:br/><w:t>break</w:t></w:r></w:p>
        <w:p><w:del><w:r><w:delText>deleted</w:delText><w:t>also deleted</w:t></w:r></w:del><w:r><w:t>visible</w:t></w:r></w:p>
        <w:tbl><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
      XML

      assert_equal "Japanese 日本語 & Vietnamese tiếng Việt\ttabbed\nbreak\nvisible\nA\tB",
                   TextExtractor.call(format: "docx", bytes: build_docx(document_xml: xml))
    end

    test "rejects malformed missing-structure macro encrypted and doctype DOCX packages" do
      malformed = "PK\x03\x04garbage".b
      missing = zip_entries("only.txt" => "nothing")
      macro = build_docx(entries: { "word/vbaProject.bin" => "macro" })
      encrypted = build_docx(encrypted: true)
      doctype = basic_document_xml.sub(
        /<w:document/,
        '<!DOCTYPE foo [<!ENTITY xxe SYSTEM "file:///etc/passwd">]><w:document'
      )

      [
        [ "malformed_docx", malformed ],
        [ "malformed_docx", missing ],
        [ "macro_docx", macro ],
        [ "encrypted_docx", encrypted ],
        [ "malformed_docx", build_docx(document_xml: doctype) ]
      ].each do |expected, bytes|
        assert_equal expected, assert_raises(Error) { DocxExtractor.call(bytes) }.code
      end
    end

    test "rejects macro content type empty body and extracted text over the source limit" do
      macro_types = CONTENT_TYPES_XML.sub(
        SourceImports::DocxExtractor::DOCUMENT_CONTENT_TYPE,
        SourceImports::DocxExtractor::MACRO_CONTENT_TYPE
      )
      macro = zip_entries(
        "[Content_Types].xml" => macro_types,
        "word/document.xml" => basic_document_xml
      )
      assert_equal "macro_docx", assert_raises(Error) { TextExtractor.call(format: "docx", bytes: macro) }.code

      empty = build_docx(document_xml: basic_document_xml(""))
      assert_equal "empty_source", assert_raises(Error) { TextExtractor.call(format: "docx", bytes: empty) }.code

      long_xml = basic_document_xml(
        "<w:p><w:r><w:t>#{'a' * (Limits::MAX_EXTRACTED_CHARACTERS + 1)}</w:t></w:r></w:p>"
      )
      too_long = build_docx(document_xml: long_xml)
      assert_equal "source_too_long", assert_raises(Error) {
        TextExtractor.call(format: "docx", bytes: too_long)
      }.code
    end

    test "does not fetch external relationships or write traversal entries" do
      marker = Rails.root.join("tmp", "docx-traversal-marker")
      bytes = build_docx(entries: {
        "word/_rels/document.xml.rels" => '<Relationships><Relationship Target="https://example.invalid/private" TargetMode="External"/></Relationships>'
      })
      assert_includes DocxExtractor.call(bytes), "Faith & hope"
      assert_not File.exist?(marker)

      traversal = zip_entries(
        "[Content_Types].xml" => CONTENT_TYPES_XML,
        "word/document.xml" => basic_document_xml,
        "../tmp/docx-traversal-marker" => "bad"
      )
      assert_equal "malformed_docx", assert_raises(Error) { DocxExtractor.call(traversal) }.code
      assert_not File.exist?(marker)
    end

    test "enforces entry count and declared archive metadata limits before extraction" do
      fake_entry = Data.define(:name, :size, :compressed_size) do
        def encrypted? = false
      end
      extractor = DocxExtractor.new(build_docx)
      archive = Data.define(:entries).new(
        Array.new(Limits::MAX_DOCX_ENTRIES + 1) { |index| fake_entry.new("safe/#{index}", 1, 1) }
      )
      assert_equal "docx_too_many_entries",
                   assert_raises(Error) { extractor.send(:inspect_archive!, archive) }.code

      huge = fake_entry.new("word/media/data.bin", Limits::MAX_DOCX_UNCOMPRESSED_BYTES + 1, 1.megabyte)
      archive = Data.define(:entries).new([ huge ])
      assert_equal "docx_uncompressed_too_large",
                   assert_raises(Error) { extractor.send(:inspect_archive!, archive) }.code

      compressed = fake_entry.new("word/media/data.bin", 2.megabytes, 1)
      archive = Data.define(:entries).new([ compressed ])
      assert_equal "suspicious_compression",
                   assert_raises(Error) { extractor.send(:inspect_archive!, archive) }.code

      duplicate = fake_entry.new("word/document.xml", 1, 1)
      archive = Data.define(:entries).new([ duplicate, duplicate ])
      assert_equal "malformed_docx",
                   assert_raises(Error) { extractor.send(:inspect_archive!, archive) }.code
    end

    test "rejects oversized relevant XML metadata" do
      fake_entry = Data.define(:name, :size, :compressed_size) do
        def encrypted? = false
      end
      entries = [
        fake_entry.new("[Content_Types].xml", 1, 1),
        fake_entry.new("word/document.xml", Limits::MAX_DOCUMENT_XML_BYTES + 1, 1.megabyte)
      ]
      archive = Data.define(:entries).new(entries)
      error = assert_raises(Error) { DocxExtractor.new(build_docx).send(:inspect_archive!, archive) }
      assert_equal "docx_xml_too_large", error.code
    end

    test "DOCX export is safe OOXML and round trips exact newline and XML semantics" do
      content = "神は愛です & <truth>\nĐức Chúa Trời — tình yêu\n"
      bytes = DocumentExports::Docx.call(title: "Title <safe>", content:)

      assert bytes.start_with?("PK")
      refute_includes zip_entry_names(bytes).map(&:downcase), "word/vbaproject.bin"
      assert_equal content, TextExtractor.call(format: "docx", bytes:)
    end

    private

    def zip_entries(entries)
      buffer = Zip::OutputStream.write_buffer do |zip|
        entries.each do |name, contents|
          zip.put_next_entry(name)
          zip.write(contents)
        end
      end
      buffer.rewind
      buffer.read
    end

    def zip_entry_names(bytes)
      names = nil
      Zip::File.open_buffer(StringIO.new(bytes)) { |archive| names = archive.entries.map(&:name) }
      names
    end
  end
end
