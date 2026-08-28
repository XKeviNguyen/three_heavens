require "stringio"
require "zip"

module DocumentExports
  class Docx
    CONTENT_TYPE = SourceImports::Detector::DOCX_MIME
    WORD_NAMESPACE = SourceImports::DocxExtractor::WORD_NAMESPACE
    PACKAGE_RELATIONSHIPS = "http://schemas.openxmlformats.org/package/2006/relationships"
    OFFICE_RELATIONSHIPS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    CORE_PROPERTIES = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
    DUBLIN_CORE = "http://purl.org/dc/elements/1.1/"

    def self.call(title:, content:)
      new(title:, content:).call
    end

    def initialize(title:, content:)
      @title = title.to_s
      @content = content.to_s
    end

    def call
      Zip::OutputStream.write_buffer do |zip|
        write(zip, "[Content_Types].xml", content_types_xml)
        write(zip, "_rels/.rels", package_relationships_xml)
        write(zip, "docProps/core.xml", core_properties_xml)
        write(zip, "word/document.xml", document_xml)
      end.tap(&:rewind).read
    end

    private

    attr_reader :title, :content

    def write(zip, name, data)
      zip.put_next_entry(name)
      zip.write(data)
    end

    def content_types_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.Types(xmlns: "http://schemas.openxmlformats.org/package/2006/content-types") do
          xml.Default(Extension: "rels", ContentType: "application/vnd.openxmlformats-package.relationships+xml")
          xml.Default(Extension: "xml", ContentType: "application/xml")
          xml.Override(PartName: "/word/document.xml", ContentType: SourceImports::DocxExtractor::DOCUMENT_CONTENT_TYPE)
          xml.Override(PartName: "/docProps/core.xml", ContentType: "application/vnd.openxmlformats-package.core-properties+xml")
        end
      end.to_xml
    end

    def package_relationships_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.Relationships(xmlns: PACKAGE_RELATIONSHIPS) do
          xml.Relationship(
            Id: "rId1",
            Type: "#{OFFICE_RELATIONSHIPS}/officeDocument",
            Target: "word/document.xml"
          )
          xml.Relationship(
            Id: "rId2",
            Type: "#{PACKAGE_RELATIONSHIPS}/metadata/core-properties",
            Target: "docProps/core.xml"
          )
        end
      end.to_xml
    end

    def core_properties_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml["cp"].coreProperties(
          "xmlns:cp" => CORE_PROPERTIES,
          "xmlns:dc" => DUBLIN_CORE
        ) do
          xml["dc"].title(title)
          xml["dc"].creator("Three Heavens")
        end
      end.to_xml
    end

    def document_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml["w"].document("xmlns:w" => WORD_NAMESPACE) do
          xml["w"].body do
            content.split("\n", -1).each { |paragraph| append_paragraph(xml, paragraph) }
            xml["w"].sectPr
          end
        end
      end.to_xml
    end

    def append_paragraph(xml, text)
      xml["w"].p do
        xml["w"].r do
          xml["w"].t(text, "xml:space" => "preserve")
        end
      end
    end
  end
end
