require "stringio"
require "zip"

module DocumentIoTestHelper
  CONTENT_TYPES_XML = <<~XML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
  XML

  def uploaded_file(bytes, filename:, content_type: "application/octet-stream")
    Rack::Test::UploadedFile.new(
      StringIO.new(bytes),
      content_type,
      true,
      original_filename: filename
    )
  end

  def build_docx(document_xml: basic_document_xml, entries: {}, encrypted: false)
    options = encrypted ? { encrypter: Zip::TraditionalEncrypter.new("test-password") } : {}
    buffer = Zip::OutputStream.write_buffer(**options) do |zip|
      {
        "[Content_Types].xml" => CONTENT_TYPES_XML,
        "word/document.xml" => document_xml
      }.merge(entries).each do |name, contents|
        zip.put_next_entry(name)
        zip.write(contents)
      end
    end
    buffer.rewind
    buffer.read
  end

  def basic_document_xml(body = nil)
    body ||= <<~XML
      <w:p><w:r><w:t>Faith &amp; hope — 信仰</w:t></w:r></w:p>
      <w:p><w:r><w:t>Đức tin</w:t><w:tab/><w:t>hy vọng</w:t><w:br/><w:t>line two</w:t></w:r></w:p>
      <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell 1</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cell 2</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    XML
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>#{body}<w:sectPr/></w:body>
      </w:document>
    XML
  end

  def create_ready_import(user:, text: "Imported source", filename: "source.txt")
    SourceImports::Create.call(
      user:,
      upload: uploaded_file(text, filename:, content_type: "text/plain")
    )
  end
end
