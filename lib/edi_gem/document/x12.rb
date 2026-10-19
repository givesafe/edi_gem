# frozen_string_literal: true

module EdiGem
  class Document
    # Addresses name a segment, optionally inside a loop -- "EB" is every EB segment in the
    # transaction, "2100C/AAA" only those in the subscriber loop. A field is an element reference
    # of the usual form, "EB01" or "AAA03".
    #
    # A trailing "[qualifier]" narrows to segments whose first element is that value:
    # "2100C/DTP[356]", "2100A/NM1[PR]".
    #
    # Loop membership comes from the HL hierarchy, so an address matches on its trailing level
    # letter (2100C and 2110C are both level C).
    #
    # The ISA is fixed-width: the delimiters are read from it by byte offset, and a body shorter
    # than an ISA parses as no segments.
    class X12 < Document
      ISA_LENGTH = 106
      ELEMENT_SEPARATOR_OFFSET = 3
      COMPONENT_SEPARATOR_OFFSET = 104
      SEGMENT_TERMINATOR_OFFSET = 105

      # HL03 hierarchical level codes, and the level each opens in a 005010X279A1 271.
      LEVELS_BY_CODE = { "20" => "A", "21" => "B", "22" => "C", "23" => "D" }.freeze
      LEVEL_SUFFIX = /([A-D])\z/

      ELEMENT_FIELD = /\A[A-Z][A-Z0-9]{1,2}(\d{2})\z/
      QUALIFIED = /\A(?<id>[A-Z][A-Z0-9]{1,2})\[(?<qualifier>[^\]]+)\]\z/

      attr_reader :segments

      def initialize(body)
        super()
        @body = body.to_s
        @segments = parse
      end

      def records(address)
        locate(address).map(&:last)
      end

      # The position is the HL levels above the segment, then the EB it follows within its level:
      # [["HL", "1"], ["HL", "2"], ["HL", "3"], ["EB", 1]] is the second benefit line at HL 3.
      def locate(address)
        matching(address).map { |segment| [segment[:at], Record.new(segment[:elements])] }
      end

      private

      def matching(address)
        level, id = split_address(address)
        id, qualifier = qualified(id)
        @segments.select do |segment|
          segment[:id] == id && (level.nil? || segment[:level] == level) &&
            (qualifier.nil? || segment[:elements].first == qualifier)
        end
      end

      def split_address(address)
        parts = address.to_s.split("/")
        return [nil, parts.first] if parts.length == 1

        [parts.first[LEVEL_SUFFIX, 1], parts.last]
      end

      def qualified(id)
        match = QUALIFIED.match(id.to_s)
        match ? [match[:id], match[:qualifier]] : [id, nil]
      end

      # Delimiters vary by sender and sit at fixed offsets in the ISA.
      def delimiters
        { element: @body[ELEMENT_SEPARATOR_OFFSET],
          component: @body[COMPONENT_SEPARATOR_OFFSET],
          segment: @body[SEGMENT_TERMINATOR_OFFSET] }
      end

      def parse
        return [] if @body.length < ISA_LENGTH

        marks = delimiters
        cursor = Cursor.new
        @body.split(marks[:segment]).filter_map do |raw|
          elements = raw.strip.split(marks[:element])
          next if elements.empty?

          cursor.step(elements)
          { id: elements.first, elements: elements.drop(1), level: cursor.level, at: cursor.at }
        end
      end

      # Tracks the position of the segment being parsed. An EB opens a benefit loop that lasts
      # until the next EB or HL.
      class Cursor
        attr_reader :level, :at

        def initialize
          @levels = {}
          @level_at = []
          @at = []
          @lines = -1
        end

        def step(elements)
          case elements.first
          when "HL" then enter(elements)
          when "EB" then @at = @level_at + [["EB", @lines += 1]]
          end
        end

        private

        def enter(elements)
          _, number, parent, code = elements
          @level = LEVELS_BY_CODE[code]
          @level_at = @levels[number] = @levels.fetch(parent, []) + [["HL", number]]
          @at = @level_at
          @lines = -1
        end
      end

      # One segment; a field is an element reference such as EB01.
      class Record < Document::Record
        def value(field)
          position = field.to_s[ELEMENT_FIELD, 1]
          position ? @node[position.to_i - 1] : nil
        end
      end
    end
  end
end
