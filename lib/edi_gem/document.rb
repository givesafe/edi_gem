# frozen_string_literal: true

module EdiGem
  # An addressable view over a Payload: which records sit at an address, and what value a record
  # holds for a field. Each dialect's address grammar is documented on its subclass.
  class Document
    def self.for(payload)
      case payload.dialect
      when :json then Document::Json.new(payload.body)
      when :x12 then Document::X12.new(payload.body)
      when :soap, :mime then Document::Envelope.new(payload.body)
      else raise ArgumentError, "no document for dialect #{payload.dialect}"
      end
    end

    # The records at an address, always an Array so no caller branches on arity.
    def records(_address)
      raise NotImplementedError
    end

    # Each record at an address paired with its position (the array steps taken to reach it).
    # Records at the same position describe the same thing.
    def locate(_address)
      raise NotImplementedError
    end

    def one(address, field)
      records(address).first&.value(field)
    end

    # A dialect's repeating unit: a JSON object, an X12 segment.
    class Record
      def initialize(node)
        @node = node
      end

      def value(_field)
        raise NotImplementedError
      end
    end
  end
end
