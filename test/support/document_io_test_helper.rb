require "stringio"
require "zip"
require "zlib"

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
    pdf_with_pages([ text ])
  end

  # One page per text, each drawn with a standard font.
  def pdf_with_pages(texts)
    build_pdf(texts.map { |text| { content: "BT /F1 12 Tf 72 720 Td (#{text}) Tj ET" } })
  end

  # A page that only paints an image, like a scan without OCR.
  def image_only_pdf
    pixels = "\x80".b * (16 * 16 * 3)
    image = "<< /Type /XObject /Subtype /Image /Width 16 /Height 16 /ColorSpace /DeviceRGB " \
      "/BitsPerComponent 8 /Length #{pixels.bytesize} >>\nstream\n".b + pixels + "\nendstream".b
    build_pdf([ { content: "q 200 0 0 200 100 400 cm /Im0 Do Q", xobject: image } ])
  end

  # A one-page text PDF whose valid Flate content stream is about a thousandth
  # of the size it inflates to while being parsed. A full flush makes every
  # mebibyte of filler compress to the same block, so the block is repeated
  # and the zlib checksum combined instead of compressing gigabytes here.
  def inflating_pdf(inflated_bytes)
    prefix = "BT /F1 12 Tf 72 720 Td (Hello) Tj ET\n"
    filler = " " * 1.megabyte
    count = inflated_bytes / filler.bytesize
    deflater = Zlib::Deflate.new(Zlib::BEST_COMPRESSION)
    compressed = deflater.deflate(prefix, Zlib::FULL_FLUSH)
    compressed << (deflater.deflate(filler, Zlib::FULL_FLUSH) * count)
    checksum = Zlib.adler32(prefix)
    filler_checksum = Zlib.adler32(filler)
    count.times { checksum = Zlib.adler32_combine(checksum, filler_checksum, filler.bytesize) }
    compressed << deflater.finish.byteslice(0...-4) << [ checksum ].pack("N")
    build_pdf([ { content: compressed, filter: "/FlateDecode" } ])
  end

  def build_pdf(pages)
    objects = [ "<< /Type /Catalog /Pages 2 0 R >>", nil, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>" ]
    kids = pages.map do |page|
      resources = +"<< /Font << /F1 3 0 R >>"
      if page[:xobject]
        objects << page[:xobject]
        resources << " /XObject << /Im0 #{objects.size} 0 R >>"
      end
      resources << " >>"
      content = page.fetch(:content).b
      filter = page[:filter] ? " /Filter #{page[:filter]}" : ""
      objects << "<< /Length #{content.bytesize}#{filter} >>\nstream\n".b + content + "\nendstream".b
      objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources #{resources} /Contents #{objects.size} 0 R >>"
      "#{objects.size} 0 R"
    end
    objects[1] = "<< /Type /Pages /Kids [#{kids.join(' ')}] /Count #{kids.size} >>"

    pdf = +"%PDF-1.4\n".b
    offsets = [ 0 ]
    objects.each_with_index do |object, index|
      offsets << pdf.bytesize
      pdf << "#{index + 1} 0 obj\n".b << object.b << "\nendobj\n".b
    end
    startxref = pdf.bytesize
    pdf << "xref\n0 #{offsets.size}\n0000000000 65535 f \n"
    offsets.drop(1).each { |offset| pdf << format("%010d 00000 n \n", offset) }
    pdf << "trailer\n<< /Size #{offsets.size} /Root 1 0 R >>\nstartxref\n#{startxref}\n%%EOF\n"
  end


  def uploaded_file(bytes, filename:, content_type: "application/octet-stream")
    Rack::Test::UploadedFile.new(
      StringIO.new(bytes),
      content_type,
      true,
      original_filename: filename
    )
  end

  # ZIP entries record a modification time, which rubyzip stamps from the
  # clock in two-second steps. A fixed time makes the same logical DOCX the
  # same bytes whenever it is built, so a test that uploads it twice under one
  # request key really replays the same file.
  DOCX_ENTRY_TIME = Time.utc(2024, 1, 1).freeze
  # Traditional ZIP encryption starts every entry with random header bytes,
  # so each encrypted DOCX is built once and its bytes reused.
  ENCRYPTED_DOCX_CACHE = {}

  def build_docx(document_xml: basic_document_xml, entries: {}, encrypted: false)
    if encrypted
      key = [ document_xml.dup.freeze, entries.transform_values { it.dup.freeze }.freeze ].freeze
      return ENCRYPTED_DOCX_CACHE[key] ||= write_docx(document_xml:, entries:, encrypted: true).freeze
    end

    write_docx(document_xml:, entries:, encrypted: false)
  end

  def write_docx(document_xml:, entries:, encrypted:)
    options = encrypted ? { encrypter: Zip::TraditionalEncrypter.new("test-password") } : {}
    buffer = Zip::OutputStream.write_buffer(**options) do |zip|
      {
        "[Content_Types].xml" => CONTENT_TYPES_XML,
        "_rels/.rels" => PACKAGE_RELATIONSHIPS_XML,
        "word/document.xml" => document_xml
      }.merge(entries).each do |name, contents|
        zip.put_next_entry(Zip::Entry.new("", name, time: DOCX_ENTRY_TIME))
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
      upload: uploaded_file(text, filename:, content_type: "text/plain"),
      request_key: ReplayIdentity.issue
    )
  end

  def source_import_binding(source_import, project: nil)
    SourceImports::ProjectBinding.issue(source_import:, project:)
  end
end
