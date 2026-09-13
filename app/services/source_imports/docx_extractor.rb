require "set"
require "stringio"
require "uri"
require "zip"

module SourceImports
  class DocxExtractor
    WORD_NAMESPACE = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    STRICT_WORD_NAMESPACE = "http://purl.oclc.org/ooxml/wordprocessingml/main"
    WORD_NAMESPACES = [ WORD_NAMESPACE, STRICT_WORD_NAMESPACE ].freeze
    CONTENT_TYPES_NAMESPACE = "http://schemas.openxmlformats.org/package/2006/content-types"
    PACKAGE_RELATIONSHIPS_NAMESPACE = "http://schemas.openxmlformats.org/package/2006/relationships"
    OFFICE_RELATIONSHIPS_NAMESPACE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    STRICT_OFFICE_RELATIONSHIPS_NAMESPACE = "http://purl.oclc.org/ooxml/officeDocument/relationships"
    OFFICE_RELATIONSHIPS_NAMESPACES = [
      OFFICE_RELATIONSHIPS_NAMESPACE,
      STRICT_OFFICE_RELATIONSHIPS_NAMESPACE
    ].freeze

    DOCUMENT_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"
    MACRO_CONTENT_TYPE = "application/vnd.ms-word.document.macroEnabled.main+xml"
    SECONDARY_CONTENT_TYPES = {
      "header" => "application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml",
      "footer" => "application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml",
      "footnotes" => "application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml",
      "endnotes" => "application/vnd.openxmlformats-officedocument.wordprocessingml.endnotes+xml",
      "numbering" => "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"
    }.freeze
    REQUIRED_ENTRIES = %w[[Content_Types].xml _rels/.rels word/document.xml].freeze
    FIXED_ENTRY_LIMITS = {
      "[Content_Types].xml" => Limits::MAX_CONTENT_TYPES_BYTES,
      "word/document.xml" => Limits::MAX_DOCUMENT_XML_BYTES
    }.freeze
    BLOCK_CONTAINERS = %w[body hdr ftr footnote endnote tc sdtContent customXml ins moveTo].freeze
    DELETED_CONTAINERS = %w[del moveFrom].freeze

    Relationship = Data.define(:id, :type, :target, :external)

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
        @archive = archive
        inspect_archive!
        validate_content_types!(read_entry("[Content_Types].xml", Limits::MAX_CONTENT_TYPES_BYTES))
        validate_relationships!
        extracted_text = extract_package
      end
      extracted_text
    rescue Error
      raise
    rescue Zip::Error, Zlib::Error, EOFError, EncodingError, URI::Error
      raise malformed_error
    ensure
      @archive = nil
    end

    private

    attr_reader :archive, :bytes

    def inspect_archive!(supplied_archive = archive)
      entries = supplied_archive.entries
      if entries.length > Limits::MAX_DOCX_ENTRIES
        raise Error.new("docx_too_many_entries", "The DOCX package exceeds safe processing limits.")
      end

      canonical_names = entries.map do |entry|
        validate_entry_name!(entry.name)
        canonical_entry_name(entry.name)
      end
      raise unsafe_archive_error if canonical_names.uniq.length != canonical_names.length

      @entries_by_name = entries.index_by(&:name)
      @read_relevant_entries = Set.new
      @relevant_xml_bytes_read = 0
      total_size = 0
      relevant_size = 0
      entries.each do |entry|
        raise Error.new("encrypted_docx", "Encrypted DOCX files are not supported.") if entry.encrypted?
        raise Error.new("macro_docx", "Macro-enabled Word documents are not supported.") if macro_entry?(entry.name)
        raise unsafe_archive_error if active_content_entry?(entry.name)
        raise malformed_error if entry.size.negative? || entry.compressed_size.negative?

        total_size += entry.size
        if total_size > Limits::MAX_DOCX_UNCOMPRESSED_BYTES
          raise Error.new("docx_uncompressed_too_large", "The DOCX package exceeds safe processing limits.")
        end
        validate_compression_ratio!(entry)

        limit = entry_limit(entry.name)
        next unless limit

        if entry.size > limit
          raise Error.new("docx_xml_too_large", "The DOCX document content exceeds safe processing limits.")
        end
        relevant_size += entry.size
        if relevant_size > Limits::MAX_RELEVANT_XML_BYTES
          raise Error.new("docx_xml_too_large", "The DOCX document content exceeds safe processing limits.")
        end
      end

      raise malformed_error if (REQUIRED_ENTRIES - @entries_by_name.keys).any?
    end

    def validate_entry_name!(name)
      valid_utf8 = name.encoding == Encoding::UTF_8 ? name.valid_encoding? : name.dup.force_encoding(Encoding::UTF_8).valid_encoding?
      raise unsafe_archive_error unless valid_utf8
      raise unsafe_archive_error if name.include?("\\") || name.include?("\0") || name.start_with?("/")

      path = name.delete_suffix("/")
      segments = path.split("/", -1)
      if path.empty? || segments.any? { |segment| segment.empty? || segment.in?(%w[. ..]) } || segments.first.match?(/\A[A-Za-z]:/)
        raise unsafe_archive_error
      end
    end

    def canonical_entry_name(name)
      name.delete_suffix("/").encode(Encoding::UTF_8).unicode_normalize(:nfc).downcase
    end

    def validate_compression_ratio!(entry)
      return if entry.size < Limits::COMPRESSION_RATIO_MINIMUM_BYTES
      if entry.compressed_size.zero? || entry.size.fdiv(entry.compressed_size) > Limits::MAX_COMPRESSION_RATIO
        raise Error.new("suspicious_compression", "The DOCX package exceeds safe compression limits.")
      end
    end

    def macro_entry?(name)
      normalized = name.downcase
      normalized.end_with?("/vbaproject.bin") || normalized.include?("/vba/")
    end

    def active_content_entry?(name)
      normalized = name.downcase
      normalized.start_with?("word/embeddings/", "word/activex/", "customui/")
    end

    def entry_limit(name)
      FIXED_ENTRY_LIMITS[name] ||
        (Limits::MAX_RELATIONSHIPS_XML_BYTES if name.end_with?(".rels")) ||
        (Limits::MAX_SECONDARY_XML_BYTES if name.match?(%r{\Aword/(?:header|footer|footnotes|endnotes|numbering)[^/]*\.xml\z}i))
    end

    def read_entry(name, limit = Limits::MAX_SECONDARY_XML_BYTES)
      entry = @entries_by_name[name]
      raise malformed_error unless entry

      unless @read_relevant_entries.include?(name)
        @read_relevant_entries << name
        @relevant_xml_bytes_read += entry.size
        if @relevant_xml_bytes_read > Limits::MAX_RELEVANT_XML_BYTES
          raise Error.new("docx_xml_too_large", "The DOCX document content exceeds safe processing limits.")
        end
      end

      entry.get_input_stream.read(limit + 1).tap do |contents|
        if contents.bytesize > limit
          raise Error.new("docx_xml_too_large", "The DOCX document content exceeds safe processing limits.")
        end
      end
    end

    def validate_content_types!(xml)
      document = parse_xml(xml)
      namespace = { "ct" => CONTENT_TYPES_NAMESPACE }
      raise malformed_error unless document.root&.name == "Types" && document.root.namespace&.href == CONTENT_TYPES_NAMESPACE

      defaults = {}
      document.xpath("/ct:Types/ct:Default", namespace).each do |node|
        extension = node["Extension"].to_s.downcase
        content_type = node["ContentType"].to_s
        raise malformed_error if extension.blank? || content_type.blank? || defaults.key?(extension)
        raise Error.new("macro_docx", "Macro-enabled Word documents are not supported.") if macro_content_type?(content_type)
        raise unsafe_archive_error if active_content_type?(content_type)
        defaults[extension] = content_type
      end

      overrides = {}
      document.xpath("/ct:Types/ct:Override", namespace).each do |node|
        part_name = node["PartName"].to_s
        content_type = node["ContentType"].to_s
        raise malformed_error unless part_name.start_with?("/") && content_type.present?

        archive_name = part_name.delete_prefix("/")
        validate_entry_name!(archive_name)
        canonical = canonical_entry_name(archive_name)
        raise malformed_error if overrides.key?(canonical)
        raise malformed_error unless @entries_by_name.key?(archive_name)
        raise Error.new("macro_docx", "Macro-enabled Word documents are not supported.") if macro_content_type?(content_type)
        raise unsafe_archive_error if active_content_type?(content_type)
        overrides[canonical] = content_type
      end

      main_type = overrides[canonical_entry_name("word/document.xml")]
      raise Error.new("macro_docx", "Macro-enabled Word documents are not supported.") if main_type == MACRO_CONTENT_TYPE
      raise malformed_error unless main_type == DOCUMENT_CONTENT_TYPE

      @content_type_defaults = defaults
      @content_type_overrides = overrides
    end

    def macro_content_type?(content_type)
      content_type.casecmp?(MACRO_CONTENT_TYPE) || content_type.downcase.include?("macroenabled") ||
        content_type.downcase.include?("vbaproject")
    end

    def active_content_type?(content_type)
      normalized = content_type.downcase
      normalized.include?("activex") || normalized.include?("oleobject")
    end

    def validate_relationships!
      @relationships_by_source = {}
      @entries_by_name.keys.grep(/\.rels\z/).sort.each do |relationship_part|
        source_part = source_part_for_relationships(relationship_part)
        raise malformed_error if source_part == :invalid

        relationships = parse_relationships(
          read_entry(relationship_part, Limits::MAX_RELATIONSHIPS_XML_BYTES),
          source_part:
        )
        raise malformed_error if @relationships_by_source.key?(source_part)
        @relationships_by_source[source_part] = relationships
      end

      office_documents = relationships_for(nil).select { |relationship| relationship.type.end_with?("/officeDocument") }
      raise malformed_error unless office_documents.one?
      main = office_documents.sole
      raise malformed_error if main.external || resolve_target(nil, main.target) != "word/document.xml"
    end

    def source_part_for_relationships(name)
      return nil if name == "_rels/.rels"

      match = name.match(%r{\A(.+)/_rels/([^/]+)\.rels\z})
      match ? "#{match[1]}/#{match[2]}" : :invalid
    end

    def parse_relationships(xml, source_part:)
      document = parse_xml(xml)
      root = document.root
      raise malformed_error unless root&.name == "Relationships" && root.namespace&.href == PACKAGE_RELATIONSHIPS_NAMESPACE

      seen_ids = Set.new
      root.element_children.map do |node|
        raise malformed_error unless node.name == "Relationship" && node.namespace&.href == PACKAGE_RELATIONSHIPS_NAMESPACE

        id = node["Id"].to_s
        type = node["Type"].to_s
        target = node["Target"].to_s
        target_mode = node["TargetMode"].presence
        raise malformed_error if id.blank? || type.blank? || target.blank? || seen_ids.include?(id)
        raise malformed_error unless target_mode.nil? || target_mode.in?(%w[Internal External])

        seen_ids << id
        external = target_mode == "External"
        if external
          raise unsafe_archive_error unless type.end_with?("/hyperlink")
        else
          resolved = resolve_target(source_part, target)
          raise malformed_error unless @entries_by_name.key?(resolved)
          if type.end_with?("/oleObject") || type.end_with?("/package") || type.end_with?("/aFChunk") ||
             type.end_with?("/control")
            raise unsafe_archive_error
          end
        end
        Relationship.new(id:, type:, target:, external:)
      end
    end

    def resolve_target(source_part, target)
      decoded = URI::DEFAULT_PARSER.unescape(target)
      if decoded.include?("\\") || decoded.include?("\0") || decoded.start_with?("/") ||
         decoded.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/) || decoded.include?("?") || decoded.include?("#")
        raise unsafe_archive_error
      end

      segments = source_part ? source_part.split("/")[0...-1] : []
      decoded.split("/", -1).each do |segment|
        case segment
        when "", "."
          raise unsafe_archive_error
        when ".."
          raise unsafe_archive_error if segments.empty?
          segments.pop
        else
          segments << segment
        end
      end
      resolved = segments.join("/")
      validate_entry_name!(resolved)
      resolved
    end

    def relationships_for(source_part)
      @relationships_by_source.fetch(source_part, [])
    end

    def extract_package
      document, namespace = parse_word_part("word/document.xml", expected_root: "document", limit: Limits::MAX_DOCUMENT_XML_BYTES)
      body = document.at_xpath("/w:document/w:body", namespace)
      raise malformed_error unless body
      raise unsupported_feature_error if body.at_xpath(".//w:altChunk", namespace)

      load_numbering!
      sections = []
      @list_counters = {}
      sections << extract_blocks(body, namespace)
      sections.concat(extract_notes(body, namespace, kind: "footnote", relationship_kind: "footnotes"))
      sections.concat(extract_notes(body, namespace, kind: "endnote", relationship_kind: "endnotes"))
      sections.concat(extract_headers_or_footers(document, namespace, kind: "header"))
      sections.concat(extract_headers_or_footers(document, namespace, kind: "footer"))
      result = sections.reject(&:nil?).join("\n\n")
      ensure_text_limit!(result)
      result
    end

    def parse_word_part(part_name, expected_root:, limit: Limits::MAX_SECONDARY_XML_BYTES)
      document = parse_xml(read_entry(part_name, limit))
      root = document.root
      raise malformed_error unless root&.name == expected_root && WORD_NAMESPACES.include?(root.namespace&.href)

      [ document, { "w" => root.namespace.href } ]
    end

    def load_numbering!
      relationships = relationships_for("word/document.xml").select { |relationship| relationship.type.end_with?("/numbering") }
      raise malformed_error if relationships.many?

      @numbering_levels = {}
      return if relationships.empty?

      relationship = relationships.sole
      raise malformed_error if relationship.external
      part_name = resolve_target("word/document.xml", relationship.target)
      validate_secondary_content_type!(part_name, "numbering")
      document, namespace = parse_word_part(part_name, expected_root: "numbering")

      abstracts = document.xpath("/w:numbering/w:abstractNum", namespace).to_h do |abstract|
        abstract_id = word_attribute(abstract, "abstractNumId")
        raise malformed_error unless integer_string?(abstract_id)
        levels = abstract.xpath("./w:lvl", namespace).to_h do |level|
          level_index = word_attribute(level, "ilvl")
          raise malformed_error unless integer_string?(level_index)
          [ level_index.to_i, numbering_level(level, namespace) ]
        end
        [ abstract_id, levels ]
      end

      document.xpath("/w:numbering/w:num", namespace).each do |num|
        num_id = word_attribute(num, "numId")
        abstract_id = word_attribute(num.at_xpath("./w:abstractNumId", namespace), "val")
        raise malformed_error unless integer_string?(num_id) && abstracts.key?(abstract_id)

        levels = abstracts.fetch(abstract_id).transform_values(&:dup)
        num.xpath("./w:lvlOverride", namespace).each do |override|
          level_index = word_attribute(override, "ilvl")
          raise malformed_error unless integer_string?(level_index)
          index = level_index.to_i
          nested_level = override.at_xpath("./w:lvl", namespace)
          levels[index] = numbering_level(nested_level, namespace) if nested_level
          start_override = word_attribute(override.at_xpath("./w:startOverride", namespace), "val")
          levels[index] = levels.fetch(index, default_numbering_level).merge(start: start_override.to_i) if integer_string?(start_override)
        end
        @numbering_levels[num_id] = levels
      end
    end

    def numbering_level(level, namespace)
      {
        format: word_attribute(level&.at_xpath("./w:numFmt", namespace), "val").presence || "decimal",
        text: word_attribute(level&.at_xpath("./w:lvlText", namespace), "val").presence || "%1.",
        start: (word_attribute(level&.at_xpath("./w:start", namespace), "val").presence || "1").to_i
      }
    end

    def default_numbering_level
      { format: "decimal", text: "%1.", start: 1 }
    end

    def extract_blocks(parent, namespace, depth: 0)
      raise unsafe_structure_error if depth > Limits::MAX_DOCX_STRUCTURE_DEPTH

      blocks = block_nodes(parent, namespace, depth:).map do |node|
        node.name == "tbl" ? extract_table(node, namespace, depth: depth + 1) : extract_paragraph(node, namespace, depth: depth + 1)
      end
      ensure_text_limit!(blocks.join("\n"))
    end

    def block_nodes(parent, namespace, depth:)
      raise unsafe_structure_error if depth > Limits::MAX_DOCX_STRUCTURE_DEPTH

      parent.element_children.flat_map do |child|
        next [] unless child.namespace&.href == namespace.fetch("w")
        next [] if DELETED_CONTAINERS.include?(child.name) || child.name == "sectPr"
        next [ child ] if child.name.in?(%w[p tbl])
        next block_nodes(child, namespace, depth: depth + 1) if BLOCK_CONTAINERS.include?(child.name) || child.element_children.any?

        []
      end
    end

    def extract_table(table, namespace, depth:)
      raise unsafe_structure_error if depth > Limits::MAX_DOCX_STRUCTURE_DEPTH

      rows = table.xpath("./w:tr", namespace).map do |row|
        row.xpath("./w:tc", namespace).map do |cell|
          extract_blocks(cell, namespace, depth: depth + 1)
        end.join("\t")
      end
      ensure_text_limit!(rows.join("\n"))
    end

    def extract_paragraph(paragraph, namespace, depth:)
      raise unsafe_structure_error if depth > Limits::MAX_DOCX_STRUCTURE_DEPTH

      text = paragraph.element_children.reject { |child| child.name == "pPr" }.map do |child|
        extract_inline(child, namespace, depth: depth + 1)
      end.join
      prefix = numbering_prefix(paragraph, namespace)
      ensure_text_limit!("#{prefix}#{text}")
    end

    def extract_inline(node, namespace, depth:)
      raise unsafe_structure_error if depth > Limits::MAX_DOCX_STRUCTURE_DEPTH
      unless node.namespace&.href == namespace.fetch("w")
        return ensure_text_limit!(node.element_children.map { |child| extract_inline(child, namespace, depth: depth + 1) }.join)
      end
      return "" if DELETED_CONTAINERS.include?(node.name)
      return "" if node.name == "r" && hidden_run?(node, namespace)

      case node.name
      when "t" then node.text
      when "tab" then "\t"
      when "br", "cr" then "\n"
      when "softHyphen" then "\u00AD"
      when "noBreakHyphen" then "\u2011"
      when "footnoteReference", "endnoteReference"
        id = word_attribute(node, "id")
        integer_string?(id) && id.to_i.positive? ? "[#{id}]" : ""
      when "txbxContent"
        extract_blocks(node, namespace, depth: depth + 1)
      when "p"
        extract_paragraph(node, namespace, depth: depth + 1)
      when "tbl"
        extract_table(node, namespace, depth: depth + 1)
      else
        ensure_text_limit!(node.element_children.map { |child| extract_inline(child, namespace, depth: depth + 1) }.join)
      end
    end

    def hidden_run?(run, namespace)
      run.at_xpath("./w:rPr/w:vanish | ./w:rPr/w:webHidden", namespace).present?
    end

    def numbering_prefix(paragraph, namespace)
      num_properties = paragraph.at_xpath("./w:pPr/w:numPr", namespace)
      return "" unless num_properties

      num_id = word_attribute(num_properties.at_xpath("./w:numId", namespace), "val")
      level_index = word_attribute(num_properties.at_xpath("./w:ilvl", namespace), "val").presence || "0"
      raise malformed_error unless integer_string?(num_id) && integer_string?(level_index)

      level_number = level_index.to_i
      levels = @numbering_levels.fetch(num_id) { raise malformed_error }
      definition = levels.fetch(level_number) { raise malformed_error }
      return "" if definition.fetch(:format) == "none"

      counters = (@list_counters[num_id] ||= [])
      counters[level_number] ||= definition.fetch(:start) - 1
      counters[level_number] += 1
      counters.slice!((level_number + 1)..) if counters.length > level_number + 1

      label = if definition.fetch(:format) == "bullet"
        bullet_label(definition.fetch(:text))
      else
        definition.fetch(:text).gsub(/%(\d+)/) do
          referenced_level = Regexp.last_match(1).to_i - 1
          referenced = levels.fetch(referenced_level, definition)
          value = counters[referenced_level] || referenced.fetch(:start)
          format_number(value, referenced.fetch(:format))
        end
      end
      "#{label}\t"
    end

    def bullet_label(value)
      value.blank? || value.match?(/[\uE000-\uF8FF]/) ? "•" : value
    end

    def format_number(value, format)
      case format
      when "lowerLetter" then alphabetic_number(value).downcase
      when "upperLetter" then alphabetic_number(value)
      when "lowerRoman" then roman_number(value).downcase
      when "upperRoman" then roman_number(value)
      else value.to_s
      end
    end

    def alphabetic_number(value)
      number = [ value, 1 ].max
      result = +""
      while number.positive?
        number -= 1
        result.prepend((65 + (number % 26)).chr)
        number /= 26
      end
      result
    end

    def roman_number(value)
      return value.to_s unless value.between?(1, 3999)

      mapping = {
        1000 => "M", 900 => "CM", 500 => "D", 400 => "CD", 100 => "C", 90 => "XC",
        50 => "L", 40 => "XL", 10 => "X", 9 => "IX", 5 => "V", 4 => "IV", 1 => "I"
      }
      number = value
      mapping.each_with_object(+"") do |(unit, glyph), result|
        count, number = number.divmod(unit)
        result << glyph * count
      end
    end

    def extract_notes(body, namespace, kind:, relationship_kind:)
      reference_ids = body.xpath(".//w:#{kind}Reference[not(ancestor::w:del) and not(ancestor::w:moveFrom)]", namespace)
                          .filter_map { |node| word_attribute(node, "id") }
                          .select { |id| integer_string?(id) && id.to_i.positive? }
                          .uniq
      return [] if reference_ids.empty?

      relationship = unique_document_relationship!(relationship_kind)
      part_name = resolve_target("word/document.xml", relationship.target)
      validate_secondary_content_type!(part_name, relationship_kind)
      document, part_namespace = parse_word_part(part_name, expected_root: relationship_kind)
      notes = document.xpath("/w:#{relationship_kind}/w:#{kind}", part_namespace).index_by do |node|
        word_attribute(node, "id")
      end
      lines = reference_ids.map do |id|
        note = notes[id]
        raise malformed_error unless note
        "[#{id}] #{extract_blocks(note, part_namespace)}"
      end
      [ "[#{relationship_kind.capitalize}]\n#{lines.join("\n")}" ]
    end

    def extract_headers_or_footers(document, namespace, kind:)
      references = document.xpath("//w:#{kind}Reference", namespace)
      seen_targets = Set.new
      references.filter_map do |reference|
        relationship_id = relationship_attribute(reference, "id")
        relationship = relationships_for("word/document.xml").find { |candidate| candidate.id == relationship_id }
        raise malformed_error unless relationship && relationship.type.end_with?("/#{kind}") && !relationship.external

        target = resolve_target("word/document.xml", relationship.target)
        next if seen_targets.include?(target)

        seen_targets << target
        validate_secondary_content_type!(target, kind)
        part, part_namespace = parse_word_part(target, expected_root: kind == "header" ? "hdr" : "ftr")
        @list_counters = {}
        text = extract_blocks(part.root, part_namespace)
        next if text.strip.empty?

        variant = word_attribute(reference, "type").presence || "default"
        "[#{kind.capitalize}: #{variant}]\n#{text}"
      end
    end

    def unique_document_relationship!(kind)
      relationships = relationships_for("word/document.xml").select { |relationship| relationship.type.end_with?("/#{kind}") }
      raise malformed_error unless relationships.one? && !relationships.sole.external

      relationships.sole
    end

    def validate_secondary_content_type!(part_name, kind)
      expected = SECONDARY_CONTENT_TYPES.fetch(kind)
      actual = @content_type_overrides[canonical_entry_name(part_name)] ||
        @content_type_defaults[File.extname(part_name).delete_prefix(".").downcase]
      raise malformed_error unless actual == expected
    end

    def word_attribute(node, name)
      return unless node

      node.attribute_nodes.find do |attribute|
        attribute.name == name && (attribute.namespace.nil? || WORD_NAMESPACES.include?(attribute.namespace.href))
      end&.value
    end

    def relationship_attribute(node, name)
      node.attribute_nodes.find do |attribute|
        attribute.name == name && OFFICE_RELATIONSHIPS_NAMESPACES.include?(attribute.namespace&.href)
      end&.value
    end

    def integer_string?(value)
      value.to_s.match?(/\A\d+\z/)
    end

    def ensure_text_limit!(text)
      if text.length > Limits::MAX_EXTRACTED_CHARACTERS
        raise Error.new(
          "source_too_long",
          "The extracted source has more than #{Limits::MAX_EXTRACTED_CHARACTERS} characters."
        )
      end
      text
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

    def unsafe_archive_error
      Error.new("unsafe_docx", "The DOCX package cannot be processed safely.")
    end

    def unsafe_structure_error
      Error.new("unsafe_docx", "The DOCX document structure exceeds safe processing limits.")
    end

    def unsupported_feature_error
      Error.new("unsupported_docx_feature", "This DOCX uses embedded document content that is not supported safely.")
    end
  end
end
