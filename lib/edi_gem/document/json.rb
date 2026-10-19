# frozen_string_literal: true

require "json"

module EdiGem
  class Document
    # Addresses are dotted paths, with a "[]" suffix on any segment that fans out over an array:
    # "benefitsInformation[]" selects one record per benefit, "subscriber.aaaErrors[]" one per
    # rejection. A field is a dotted path relative to the record.
    class Json < Document
      ARRAY_SUFFIX = "[]"

      # Raises UnreadableBody, a gem error, rather than the parser's own.
      def self.parse(body)
        JSON.parse(body)
      rescue JSON::ParserError => error
        raise UnreadableBody, "the body is not JSON (#{error.class})"
      end

      def initialize(body)
        super()
        @root = body.is_a?(String) ? self.class.parse(body) : body
      end

      def records(address)
        locate(address).map(&:last)
      end

      # The position is each array step as [key, index], so `items[0].benefitsInformation[1]` is
      # [["items", 0], ["benefitsInformation", 1]].
      def locate(address)
        reached = address.to_s.split(".").reduce([[[], @root]]) { |found, step| descend(found, step) }
        reached.filter_map { |at, node| [at, Record.new(node)] unless node.nil? }
      end

      private

      def descend(found, step)
        fans_out = step.end_with?(ARRAY_SUFFIX)
        key = fans_out ? step.delete_suffix(ARRAY_SUFFIX) : step
        found.filter_map { |at, node| [at, node[key]] if node.is_a?(Hash) }
             .flat_map { |at, node| fans_out ? fanned(at, key, node) : [[at, node]] }
      end

      # A lone object where a list is expected is read as a list of one.
      def fanned(at, key, node)
        elements = node.is_a?(Array) ? node : [node]
        elements.each_with_index.map { |element, index| [at + [[key, index]], element] }
      end

      # One JSON object; a field is a dotted path relative to it.
      class Record < Document::Record
        def value(field)
          field.to_s.split(".").reduce(@node) { |node, key| node.is_a?(Hash) ? node[key] : nil }
        end
      end
    end
  end
end
