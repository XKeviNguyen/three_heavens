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

  PACKAGE_RELATIONSHIPS_XML = <<~XML.freeze
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
  XML

  def pdf_with_text(text)
    stream = "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET"
    objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\nendstream"
    ]
    pdf = +"%PDF-1.4\n"
    offsets = [ 0 ]
    objects.each_with_index do |object, index|
      offsets << pdf.bytesize
      pdf << "#{index + 1} 0 obj\n#{object}\nendobj\n"
    end
    startxref = pdf.bytesize
    pdf << "xref\n0 #{offsets.size}\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{offsets.size} /Root 1 0 R >>\nstartxref\n#{startxref}\n%%EOF\n"
    pdf.b
  end


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
        "_rels/.rels" => PACKAGE_RELATIONSHIPS_XML,
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

  def source_import_binding(source_import, project: nil)
    SourceImports::ProjectBinding.issue(source_import:, project:)
  end
end
