# frozen_string_literal: true

module EdiGem
  class Document
    # A CAQH CORE envelope, SOAP or MIME multipart. The address "envelope" reads its metadata;
    # every other address reads the X12 payload inside. An envelope error means no payer saw the
    # request.
    class Envelope < Document
      METADATA = %w[PayloadType ProcessingMode PayloadID TimeStamp SenderID ReceiverID
                    CORERuleVersion PayloadLength CheckSum ErrorCode ErrorMessage].freeze

      ERROR_PAYLOAD_TYPE = "CoreEnvelopeError"
      SUCCESS = "Success"
      METADATA_ADDRESS = "envelope"

      def initialize(body)
        super()
        @body = body.to_s
      end

      def records(address)
        locate(address).map(&:last)
      end

      def locate(address)
        address.to_s == METADATA_ADDRESS ? [[[], Record.new(metadata)]] : payload_document.locate(address)
      end

      def metadata
        @metadata ||= METADATA.to_h { |field| [field, extract(field)] }.compact
      end

      def payload_document
        @payload_document ||= Document::X12.new(extract("Payload").to_s)
      end

      def error?
        metadata["PayloadType"] == ERROR_PAYLOAD_TYPE ||
          (metadata["ErrorCode"] && metadata["ErrorCode"] != SUCCESS)
      end

      private

      # The namespace prefix varies by sender and is ignored.
      def extract(field)
        @body[%r{<(?:\w+:)?#{Regexp.escape(field)}>(.*?)</(?:\w+:)?#{Regexp.escape(field)}>}m, 1]
      end

      # The envelope metadata itself, addressed by CORE field name.
      class Record < Document::Record
        def value(field)
          @node[field.to_s]
        end
      end
    end
  end
end
