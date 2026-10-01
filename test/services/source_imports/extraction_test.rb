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

    test "the DOCX test builder gives the same bytes for the same document whenever it runs" do
      inputs = [ {}, { document_xml: "not valid XML" }, { entries: { "word/vbaProject.bin" => "macro" } }, { encrypted: true } ]
      first = inputs.map { |input| Digest::SHA256.hexdigest(build_docx(**input)) }
      travel 3.seconds
      again = inputs.map { |input| Digest::SHA256.hexdigest(build_docx(**input)) }

      assert_equal first, again
      assert_equal inputs.size, first.uniq.size
    end

    test "detects only explicit supported extensions with matching content" do
      assert_equal "txt", Detector.call(filename: "source.TXT", bytes: "text").format
      assert_equal "md", Detector.call(filename: "source.md", bytes: "# text").format
      assert_equal "md", Detector.call(filename: "source.md", bytes: "<script>alert('source')</script>").format
      assert_equal "docx", Detector.call(filename: "source.docx", bytes: build_docx).format

      assert_equal "unsupported_format", assert_raises(Error) {
        Detector.call(filename: "source.rtf", bytes: "text")
      }.code
      assert_equal "mismatched_type", assert_raises(Error) {
        Detector.call(filename: "source.txt", bytes: build_docx)
      }.code
      assert_equal "mismatched_type", assert_raises(Error) {
        Detector.call(filename: "source.md", bytes: "# text", declared_content_type: Detector::DOCX_MIME)
      }.code
      assert_equal "empty_source", assert_raises(Error) {
        TextExtractor.call(format: Detector.call(filename: "empty.txt", bytes: "").format, bytes: "")
      }.code
    end

    test "detects genuine DOCX with the common x-zip-compressed declaration" do
      result = Detector.call(
        filename: "source.docx",
        bytes: build_docx,
        declared_content_type: "application/x-zip-compressed"
      )

      assert_equal "docx", result.format
      assert_equal Detector::DOCX_MIME, result.content_type
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

    test "extracts visible hyperlinks controls revisions text boxes fields and hyphens" do
      xml = basic_document_xml(<<~XML)
        <w:sdt><w:sdtContent><w:p><w:hyperlink><w:r><w:t>Linked</w:t></w:r></w:hyperlink><w:r><w:tab/><w:t>control</w:t></w:r></w:p></w:sdtContent></w:sdt>
        <w:p><w:ins><w:r><w:t>inserted</w:t></w:r></w:ins><w:moveTo><w:r><w:t> and moved here</w:t></w:r></w:moveTo><w:moveFrom><w:r><w:t>moved away</w:t></w:r></w:moveFrom><w:r><w:rPr><w:vanish/></w:rPr><w:t>hidden</w:t></w:r><w:r><w:softHyphen/><w:t>soft</w:t><w:noBreakHyphen/><w:t>fixed</w:t></w:r></w:p>
        <w:p><w:fldSimple w:instr="DATE"><w:r><w:t>January 1</w:t></w:r></w:fldSimple></w:p>
        <w:p><w:r><w:t>Before </w:t></w:r><w:r><w:drawing><x:inline xmlns:x="urn:non-word"><x:graphic><w:txbxContent><w:p><w:r><w:t>Box one</w:t></w:r></w:p><w:p><w:r><w:t>Box two</w:t></w:r></w:p></w:txbxContent></x:graphic></x:inline></w:drawing></w:r></w:p>
      XML

      assert_equal "Linked\tcontrol\ninserted and moved here\u00ADsoft\u2011fixed\nJanuary 1\nBefore Box one\nBox two",
                   TextExtractor.call(format: "docx", bytes: build_docx(document_xml: xml))
    end

    test "honors WordprocessingML on-off values for hidden run properties" do
      xml = basic_document_xml(<<~XML)
        <w:p>
          <w:r><w:t>Visible:</w:t></w:r>
          <w:r><w:rPr><w:vanish w:val="0"/></w:rPr><w:t> vanish-zero</w:t></w:r>
          <w:r><w:rPr><w:vanish w:val="false"/></w:rPr><w:t> vanish-false</w:t></w:r>
          <w:r><w:rPr><w:vanish w:val="off"/></w:rPr><w:t> vanish-off</w:t></w:r>
          <w:r><w:rPr><w:webHidden w:val="0"/></w:rPr><w:t> web-zero</w:t></w:r>
          <w:r><w:rPr><w:webHidden w:val="false"/></w:rPr><w:t> web-false</w:t></w:r>
          <w:r><w:rPr><w:webHidden w:val="off"/></w:rPr><w:t> web-off</w:t></w:r>
          <w:r><w:rPr><w:vanish/></w:rPr><w:t> hidden-default</w:t></w:r>
          <w:r><w:rPr><w:vanish w:val="1"/></w:rPr><w:t> hidden-one</w:t></w:r>
          <w:r><w:rPr><w:webHidden w:val="true"/></w:rPr><w:t> hidden-true</w:t></w:r>
          <w:r><w:rPr><w:webHidden w:val="on"/></w:rPr><w:t> hidden-on</w:t></w:r>
        </w:p>
      XML

      assert_equal "Visible: vanish-zero vanish-false vanish-off web-zero web-false web-off",
                   TextExtractor.call(format: "docx", bytes: build_docx(document_xml: xml))
    end

    test "preserves blank paragraphs multi-row tables and bounded nested tables" do
      xml = basic_document_xml(<<~XML)
        <w:p><w:r><w:t>Before</w:t></w:r></w:p>
        <w:p/>
        <w:tbl>
          <w:tr><w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p><w:p><w:r><w:t>A2</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc><w:tc><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Nested</w:t></w:r></w:p></w:tc></w:tr></w:tbl></w:tc></w:tr>
        </w:tbl>
      XML

      assert_equal "Before\n\nA1\nA2\tB\nC\tNested",
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
        "_rels/.rels" => PACKAGE_RELATIONSHIPS_XML,
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
        "word/_rels/document.xml.rels" => <<~XML
          <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
            <Relationship Id="rIdLink" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" Target="https://example.invalid/private" TargetMode="External"/>
          </Relationships>
        XML
      })
      assert_includes DocxExtractor.call(bytes), "Faith & hope"
      assert_not File.exist?(marker)

      traversal = zip_entries(
        "[Content_Types].xml" => CONTENT_TYPES_XML,
        "_rels/.rels" => PACKAGE_RELATIONSHIPS_XML,
        "word/document.xml" => basic_document_xml,
        "../tmp/docx-traversal-marker" => "bad"
      )
      assert_equal "unsafe_docx", assert_raises(Error) { DocxExtractor.call(traversal) }.code
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
      assert_equal "unsafe_docx",
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

    test "extracts deterministic numbering notes headers and footers exactly once" do
      content_types = CONTENT_TYPES_XML.sub(
        "</Types>",
        <<~XML
          <Override PartName="/word/numbering.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("numbering")}"/>
          <Override PartName="/word/footnotes.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("footnotes")}"/>
          <Override PartName="/word/endnotes.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("endnotes")}"/>
          <Override PartName="/word/header1.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("header")}"/>
          <Override PartName="/word/footer1.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("footer")}"/>
        </Types>
        XML
      )
      relationships = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rNum" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>
          <Relationship Id="rNotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>
          <Relationship Id="rEndnotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes" Target="endnotes.xml"/>
          <Relationship Id="rHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
          <Relationship Id="rFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        </Relationships>
      XML
      body = <<~XML
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>First</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Second</w:t><w:footnoteReference w:id="1"/></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="2"/></w:numPr></w:pPr><w:r><w:t>Bullet</w:t></w:r></w:p>
        <w:p><w:r><w:t>End matter</w:t><w:endnoteReference w:id="2"/></w:r></w:p>
        <w:sectPr><w:headerReference w:type="default" r:id="rHeader"/><w:headerReference w:type="default" r:id="rHeader"/><w:footerReference w:type="default" r:id="rFooter"/></w:sectPr>
      XML
      document = basic_document_xml(body).sub(
        "<w:document ",
        '<w:document xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      )
      numbering = <<~XML
        <w:numbering xmlns:w="#{DocxExtractor::WORD_NAMESPACE}">
          <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>
          <w:abstractNum w:abstractNumId="1"><w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/><w:lvlText w:val=""/></w:lvl></w:abstractNum>
          <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
          <w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
      XML
      footnotes = <<~XML
        <w:footnotes xmlns:w="#{DocxExtractor::WORD_NAMESPACE}">
          <w:footnote w:id="-1"><w:p><w:r><w:t>separator</w:t></w:r></w:p></w:footnote>
          <w:footnote w:id="1"><w:p><w:r><w:t>Author note</w:t></w:r></w:p></w:footnote>
        </w:footnotes>
      XML
      endnotes = <<~XML
        <w:endnotes xmlns:w="#{DocxExtractor::WORD_NAMESPACE}">
          <w:endnote w:id="0"><w:p><w:r><w:t>separator</w:t></w:r></w:p></w:endnote>
          <w:endnote w:id="2"><w:p><w:r><w:t>Author endnote</w:t></w:r></w:p></w:endnote>
        </w:endnotes>
      XML
      bytes = build_docx(document_xml: document, entries: {
        "[Content_Types].xml" => content_types,
        "word/_rels/document.xml.rels" => relationships,
        "word/numbering.xml" => numbering,
        "word/footnotes.xml" => footnotes,
        "word/endnotes.xml" => endnotes,
        "word/header1.xml" => "<w:hdr xmlns:w=\"#{DocxExtractor::WORD_NAMESPACE}\"><w:p><w:r><w:t>Only once</w:t></w:r></w:p></w:hdr>",
        "word/footer1.xml" => "<w:ftr xmlns:w=\"#{DocxExtractor::WORD_NAMESPACE}\"><w:p><w:r><w:t>Footer</w:t></w:r></w:p></w:ftr>"
      })

      assert_equal <<~TEXT.chomp, TextExtractor.call(format: "docx", bytes:)
        1.\tFirst
        2.\tSecond[1]
        •\tBullet
        End matter[2]

        [Footnotes]
        [1] Author note

        [Endnotes]
        [2] Author endnote

        [Header: default]
        Only once

        [Footer: default]
        Footer
      TEXT
    end

    test "includes only notes referenced by visible current text" do
      content_types = CONTENT_TYPES_XML.sub(
        "</Types>",
        <<~XML
          <Override PartName="/word/footnotes.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("footnotes")}"/>
          <Override PartName="/word/endnotes.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("endnotes")}"/>
        </Types>
        XML
      )
      relationships = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rFootnotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footnotes" Target="footnotes.xml"/>
          <Relationship Id="rEndnotes" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/endnotes" Target="endnotes.xml"/>
        </Relationships>
      XML
      body = <<~XML
        <w:p><w:r><w:t>Visible footnote</w:t><w:footnoteReference w:id="1"/></w:r></w:p>
        <w:p><w:r><w:rPr><w:vanish/></w:rPr><w:footnoteReference w:id="2"/></w:r></w:p>
        <w:p><w:r><w:rPr><w:vanish w:val="false"/></w:rPr><w:t>False vanish</w:t><w:footnoteReference w:id="3"/></w:r></w:p>
        <w:p><w:del><w:r><w:footnoteReference w:id="4"/></w:r></w:del><w:moveFrom><w:r><w:footnoteReference w:id="5"/></w:r></w:moveFrom></w:p>
        <w:p><w:r><w:t>Visible endnote</w:t><w:endnoteReference w:id="6"/></w:r></w:p>
        <w:p><w:r><w:rPr><w:webHidden w:val="on"/></w:rPr><w:endnoteReference w:id="7"/></w:r></w:p>
        <w:p><w:r><w:rPr><w:webHidden w:val="off"/></w:rPr><w:t>False web hidden</w:t><w:endnoteReference w:id="8"/></w:r></w:p>
      XML
      footnotes = <<~XML
        <w:footnotes xmlns:w="#{DocxExtractor::WORD_NAMESPACE}">
          #{(1..5).map { |id| %(<w:footnote w:id="#{id}"><w:p><w:r><w:t>Footnote #{id}</w:t></w:r></w:p></w:footnote>) }.join}
        </w:footnotes>
      XML
      endnotes = <<~XML
        <w:endnotes xmlns:w="#{DocxExtractor::WORD_NAMESPACE}">
          #{(6..8).map { |id| %(<w:endnote w:id="#{id}"><w:p><w:r><w:t>Endnote #{id}</w:t></w:r></w:p></w:endnote>) }.join}
        </w:endnotes>
      XML
      bytes = build_docx(document_xml: basic_document_xml(body), entries: {
        "[Content_Types].xml" => content_types,
        "word/_rels/document.xml.rels" => relationships,
        "word/footnotes.xml" => footnotes,
        "word/endnotes.xml" => endnotes
      })

      assert_equal <<~TEXT.chomp, TextExtractor.call(format: "docx", bytes:)
        Visible footnote[1]

        False vanish[3]

        Visible endnote[6]

        False web hidden[8]

        [Footnotes]
        [1] Footnote 1
        [3] Footnote 3

        [Endnotes]
        [6] Endnote 6
        [8] Endnote 8
      TEXT
    end

    test "treats numbering id zero as removal of numbering" do
      body = <<~XML
        <w:p><w:pPr><w:numPr><w:numId w:val="0"/></w:numPr></w:pPr><w:r><w:t>Plain paragraph</w:t></w:r></w:p>
      XML

      assert_equal "Plain paragraph", TextExtractor.call(format: "docx", bytes: build_docx(document_xml: basic_document_xml(body)))
    end

    test "extracts active section headers and footers without reading historical sectPrChange references" do
      content_types = CONTENT_TYPES_XML.sub(
        "</Types>",
        <<~XML
          <Override PartName="/word/header1.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("header")}"/>
          <Override PartName="/word/footer1.xml" ContentType="#{DocxExtractor::SECONDARY_CONTENT_TYPES.fetch("footer")}"/>
        </Types>
        XML
      )
      relationships = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rHeader" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/header" Target="header1.xml"/>
          <Relationship Id="rFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        </Relationships>
      XML
      body = <<~XML
        <w:p><w:r><w:t>Current body</w:t></w:r></w:p>
        <w:sectPr>
          <w:headerReference w:type="default" r:id="rHeader"/>
          <w:footerReference w:type="default" r:id="rFooter"/>
          <w:sectPrChange><w:sectPr><w:headerReference r:id="rRemovedHeader"/><w:footerReference r:id="rRemovedFooter"/></w:sectPr></w:sectPrChange>
        </w:sectPr>
      XML
      document = basic_document_xml(body).sub(
        "<w:document ",
        '<w:document xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      )
      bytes = build_docx(document_xml: document, entries: {
        "[Content_Types].xml" => content_types,
        "word/_rels/document.xml.rels" => relationships,
        "word/header1.xml" => "<w:hdr xmlns:w=\"#{DocxExtractor::WORD_NAMESPACE}\"><w:p><w:r><w:t>Current header</w:t></w:r></w:p></w:hdr>",
        "word/footer1.xml" => "<w:ftr xmlns:w=\"#{DocxExtractor::WORD_NAMESPACE}\"><w:p><w:r><w:t>Current footer</w:t></w:r></w:p></w:ftr>"
      })

      assert_equal <<~TEXT.chomp, TextExtractor.call(format: "docx", bytes:)
        Current body

        [Header: default]
        Current header

        [Footer: default]
        Current footer
      TEXT
    end

    test "accepts relationship parts for package root root-level and nested parts only" do
      root_part_relationships = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rRootTarget" Type="urn:test" Target="root-target.xml"/>
        </Relationships>
      XML
      nested_part_relationships = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rNestedTarget" Type="urn:test" Target="nested-target.xml"/>
        </Relationships>
      XML
      valid = build_docx(entries: {
        "custom.xml" => "<custom/>",
        "root-target.xml" => "<target/>",
        "_rels/custom.xml.rels" => root_part_relationships,
        "word/custom.xml" => "<custom/>",
        "word/nested-target.xml" => "<target/>",
        "word/_rels/custom.xml.rels" => nested_part_relationships
      })

      assert_includes DocxExtractor.call(valid), "Faith & hope"

      orphan = build_docx(entries: {
        "root-target.xml" => "<target/>",
        "_rels/ghost.xml.rels" => root_part_relationships
      })
      assert_equal "malformed_docx", assert_raises(Error) { DocxExtractor.call(orphan) }.code

      malformed = build_docx(entries: { "_rels/nested/custom.xml.rels" => root_part_relationships })
      assert_equal "malformed_docx", assert_raises(Error) { DocxExtractor.call(malformed) }.code

      traversal = build_docx(entries: { "_rels/../custom.xml.rels" => root_part_relationships })
      assert_equal "unsafe_docx", assert_raises(Error) { DocxExtractor.call(traversal) }.code

      traversal_target = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rTraversal" Type="urn:test" Target="../outside.xml"/>
        </Relationships>
      XML
      unsafe_target = build_docx(entries: {
        "custom.xml" => "<custom/>",
        "outside.xml" => "<outside/>",
        "_rels/custom.xml.rels" => traversal_target
      })
      assert_equal "unsafe_docx", assert_raises(Error) { DocxExtractor.call(unsafe_target) }.code
    end

    test "rejects duplicate package declarations unsafe external parts and embedded objects" do
      duplicate_types = CONTENT_TYPES_XML.sub(
        "</Types>",
        "<Override PartName=\"/word/document.xml\" ContentType=\"#{DocxExtractor::DOCUMENT_CONTENT_TYPE}\"/></Types>"
      )
      duplicate_main = PACKAGE_RELATIONSHIPS_XML.sub(
        "</Relationships>",
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
      )
      external_image = <<~XML
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rIdImage" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="https://example.invalid/image" TargetMode="External"/>
        </Relationships>
      XML

      assert_equal "malformed_docx", assert_raises(Error) {
        DocxExtractor.call(build_docx(entries: { "[Content_Types].xml" => duplicate_types }))
      }.code
      assert_equal "malformed_docx", assert_raises(Error) {
        DocxExtractor.call(build_docx(entries: { "_rels/.rels" => duplicate_main }))
      }.code
      assert_equal "unsafe_docx", assert_raises(Error) {
        DocxExtractor.call(build_docx(entries: { "word/_rels/document.xml.rels" => external_image }))
      }.code
      assert_equal "unsafe_docx", assert_raises(Error) {
        DocxExtractor.call(build_docx(entries: { "word/embeddings/object1.bin" => "object" }))
      }.code
    end

    test "app-generated DOCX round trips the supported authoritative text contract" do
      samples = [
        "ASCII punctuation: faith, hope; love!",
        "Tiếng Việt: Đức Chúa Trời yêu thương.",
        "日本語の翻訳。",
        "Mixed 日本語 — tiếng Việt — English",
        "first\n\nthird",
        "tabs\tinside\tlines\nline two\n",
        ("Long bounded paragraph 日本語. " * 1_000).strip
      ]

      samples.each do |content|
        bytes = DocumentExports::Docx.call(title: "Safe title", content:)
        assert_equal content, TextExtractor.call(format: "docx", bytes:)
      end
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
