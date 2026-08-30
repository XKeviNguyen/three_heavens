module LongDocuments
  class SegmentReassembler
    BOUNDARY_PATTERN = /[[:space:]]+\z/

    def self.call(parts)
      ordered = parts.sort_by { |segment, _output| segment.position }
      ordered.each_with_index.map do |(segment, output), index|
        next output if index == ordered.length - 1

        boundary = segment.source_text[BOUNDARY_PATTERN].to_s
        output.sub(BOUNDARY_PATTERN, "") + boundary
      end.join
    end
  end
end
