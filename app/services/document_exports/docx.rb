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
        write(zip, "word/_rels/document.xml.rels", document_relationships_xml)
        write(zip, "word/styles.xml", styles_xml)
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
          xml.Override(PartName: "/word/styles.xml", ContentType: "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml")
          xml.Override(PartName: "/docProps/core.xml", ContentType: "application/vnd.openxmlformats-package.core-properties+xml")
        end
      end.to_xml
    end

    def document_relationships_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.Relationships(xmlns: PACKAGE_RELATIONSHIPS) do
          xml.Relationship(
            Id: "rId1",
            Type: "#{OFFICE_RELATIONSHIPS}/styles",
            Target: "styles.xml"
          )
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
        text.split("\t", -1).each_with_index do |segment, index|
          xml["w"].r { xml["w"].tab } if index.positive?
          next if segment.empty?

          xml["w"].r do
            xml["w"].t(segment, "xml:space" => "preserve")
          end
        end
      end
    end

    def styles_xml
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml["w"].styles("xmlns:w" => WORD_NAMESPACE) do
          xml["w"].docDefaults do
            xml["w"].rPrDefault do
              xml["w"].rPr do
                xml["w"].rFonts("w:ascii" => "Aptos", "w:hAnsi" => "Aptos", "w:eastAsia" => "Aptos")
                xml["w"].sz("w:val" => "22")
                xml["w"].szCs("w:val" => "22")
              end
            end
            xml["w"].pPrDefault do
              xml["w"].pPr do
                xml["w"].spacing("w:after" => "120", "w:line" => "276", "w:lineRule" => "auto")
              end
            end
          end
          xml["w"].style("w:type" => "paragraph", "w:default" => "1", "w:styleId" => "Normal") do
            xml["w"].name("w:val" => "Normal")
          end
        end
      end.to_xml
    end
  end
end
