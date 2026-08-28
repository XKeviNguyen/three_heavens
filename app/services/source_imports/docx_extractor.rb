require "stringio"
require "zip"

module SourceImports
  class DocxExtractor
    WORD_NAMESPACE = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    CONTENT_TYPES_NAMESPACE = "http://schemas.openxmlformats.org/package/2006/content-types"
    DOCUMENT_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
    MACRO_CONTENT_TYPE = "application/vnd.ms-word.document.macroEnabled.main+xml"
    REQUIRED_ENTRIES = %w[[Content_Types].xml word/document.xml].freeze
    RELEVANT_ENTRY_LIMITS = {
      "[Content_Types].xml" => Limits::MAX_CONTENT_TYPES_BYTES,
      "word/document.xml" => Limits::MAX_DOCUMENT_XML_BYTES
    }.freeze

    def self.call(bytes)
      new(bytes).call
    end

    def initialize(bytes)
      @bytes = bytes
    end

    def call
      raise malformed_error unless bytes.start_with?("PK\x03\x04".b)

      extracted_text = nil
      Zip::File.open_buffer(StringIO.new(bytes)) do |archive|
        inspect_archive!(archive)
        validate_content_types!(read_entry(archive, "[Content_Types].xml"))
        extracted_text = extract_document(read_entry(archive, "word/document.xml"))
      end
      extracted_text
    rescue Zip::Error, Zlib::Error, EOFError
      raise malformed_error
    end

    private

    attr_reader :bytes

    def inspect_archive!(archive)
      entries = archive.entries
      raise Error.new("docx_too_many_entries", "The DOCX package exceeds safe processing limits.") if entries.length > Limits::MAX_DOCX_ENTRIES
      raise malformed_error if entries.map(&:name).uniq.length != entries.length

      total_size = 0
      entries.each do |entry|
        validate_entry_name!(entry.name)
        raise Error.new("encrypted_docx", "Encrypted DOCX files are not supported.") if entry.encrypted?
        raise Error.new("macro_docx", "Macro-enabled Word documents are not supported.") if macro_entry?(entry.name)
        raise malformed_error if entry.size.negative? || entry.compressed_size.negative?

        total_size += entry.size
        if total_size > Limits::MAX_DOCX_UNCOMPRESSED_BYTES
          raise Error.new("docx_uncompressed_too_large", "The DOCX package exceeds safe processing limits.")
        end
        validate_compression_ratio!(entry)

        relevant_limit = RELEVANT_ENTRY_LIMITS[entry.name]
        if relevant_limit && entry.size > relevant_limit
          raise Error.new("docx_xml_too_large", "The DOCX document content exceeds safe processing limits.")
        end
      end

      missing = REQUIRED_ENTRIES - entries.map(&:name)
      raise malformed_error if missing.any?
    end

    def validate_entry_name!(name)
      normalized = name.tr("\\", "/")
      segments = normalized.split("/")
      return unless normalized.start_with?("/") || segments.include?("..") || name.include?("\\")

      raise malformed_error
    end

    def validate_compression_ratio!(entry)
      return if entry.size < Limits::COMPRESSION_RATIO_MINIMUM_BYTES
      if entry.compressed_size.zero? || entry.size.fdiv(entry.compressed_size) > Limits::MAX_COMPRESSION_RATIO
        raise Error.new("suspicious_compression", "The DOCX package exceeds safe compression limits.")
      end
    end

    def macro_entry?(name)
      name.casecmp?("word/vbaProject.bin") || name.downcase.end_with?("/vbaproject.bin")
    end

    def read_entry(archive, name)
      entry = archive.find_entry(name)
      raise malformed_error unless entry

      entry.get_input_stream.read(RELEVANT_ENTRY_LIMITS.fetch(name) + 1).tap do |contents|
        raise Error.new("docx_xml_too_large", "The DOCX document content exceeds safe processing limits.") if contents.bytesize > RELEVANT_ENTRY_LIMITS.fetch(name)
      end
    end

    def validate_content_types!(xml)
      document = parse_xml(xml)
      namespace = { "ct" => CONTENT_TYPES_NAMESPACE }
      overrides = document.xpath("/ct:Types/ct:Override", namespace)
      main = overrides.find { |node| node["PartName"] == "/word/document.xml" }
      raise malformed_error unless main
      raise Error.new("macro_docx", "Macro-enabled Word documents are not supported.") if main["ContentType"] == MACRO_CONTENT_TYPE
      raise malformed_error unless main["ContentType"] == DOCUMENT_CONTENT_TYPE
    end

    def extract_document(xml)
      document = parse_xml(xml)
      namespace = { "w" => WORD_NAMESPACE }
      body = document.at_xpath("/w:document/w:body", namespace)
      raise malformed_error unless body

      blocks = body.xpath("./w:p | ./w:tbl", namespace).filter_map do |node|
        node.name == "tbl" ? extract_table(node, namespace) : extract_paragraph(node, namespace)
      end
      blocks.join("\n")
    end

    def extract_table(table, namespace)
      table.xpath("./w:tr", namespace).map do |row|
        row.xpath("./w:tc", namespace).map do |cell|
          cell.xpath("./w:p | ./w:tbl", namespace).map do |node|
            node.name == "tbl" ? extract_table(node, namespace) : extract_paragraph(node, namespace)
          end.join("\n")
        end.join("\t")
      end.join("\n")
    end

    def extract_paragraph(paragraph, namespace)
      paragraph.xpath(
        ".//w:t[not(ancestor::w:del)] | .//w:tab[not(ancestor::w:del)] | " \
          ".//w:br[not(ancestor::w:del)] | .//w:cr[not(ancestor::w:del)]",
        namespace
      ).map do |node|
        case node.name
        when "tab" then "\t"
        when "br", "cr" then "\n"
        else node.text
        end
      end.join
    end

    def parse_xml(xml)
      document = Nokogiri::XML(xml) { |config| config.strict.nonet }
      raise malformed_error if document.internal_subset

      document
    rescue Nokogiri::XML::SyntaxError
      raise malformed_error
    end

    def malformed_error
      Error.new("malformed_docx", "The selected file is not a valid DOCX document.")
    end
  end
end
