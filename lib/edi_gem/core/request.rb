# frozen_string_literal: true

require "securerandom"
require "time"

module EdiGem
  module Core
    # A CAQH CORE Connectivity vC2.2.0 envelope around an X12 payload, written as SOAP or as
    # HTTP MIME multipart. Document::Envelope reads both.
    #
    # A request refused at the envelope never reached a payer and is not a coverage answer.
    class Request
      RULE_VERSION = "2.2.0"

      # ProcessingMode. Batch results are retrieved by a separate call.
      REAL_TIME = "RealTime"
      BATCH = "Batch"

      # PayloadType values from the rule's enumeration (005010).
      ELIGIBILITY_REQUEST = "X12_270_Request_005010X279A1"
      BATCH_SUBMISSION = "X12_005010_Request_BatchSubmissionMixed"
      BATCH_RESULTS = "X12_005010_Request_Batch_Results_271"

      SOAP_NAMESPACE = "http://www.w3.org/2003/05/soap-envelope"
      WSSE = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd"
      CORE_NAMESPACE = "http://www.caqh.org/SOAP/WSDL/CORETransactions"

      # In the order the CORE schema declares; receivers validating against the WSDL check it.
      FIELDS = %w[PayloadType ProcessingMode PayloadID TimeStamp SenderID ReceiverID
                  CORERuleVersion].freeze

      # `payload_id` is a UUID, generated unless given. The rule reuses it when a payload is
      # resent, so pass the original on a resend.
      def initialize(payload:, sender:, receiver:, payload_type: ELIGIBILITY_REQUEST,
                     mode: REAL_TIME, payload_id: nil, username: nil, password: nil, now: nil)
        @payload = payload.to_s
        @sender = sender
        @receiver = receiver
        @payload_type = payload_type
        @mode = mode
        @payload_id = payload_id || SecureRandom.uuid
        @username = username
        @password = password
        @now = now || Time.now
      end

      attr_reader :payload_id

      def soap
        <<~XML
          <?xml version="1.0" encoding="UTF-8"?>
          <soap:Envelope xmlns:soap="#{SOAP_NAMESPACE}" xmlns:core="#{CORE_NAMESPACE}">
            <soap:Header>#{security}</soap:Header>
            <soap:Body>
              <core:#{element}>
          #{metadata.map { |name, value| "      <#{name}>#{escape(value)}</#{name}>" }.join("\n")}
                <Payload>#{escape(@payload)}</Payload>
              </core:#{element}>
            </soap:Body>
          </soap:Envelope>
        XML
      end

      # The MIME multipart form, which needs no SOAP stack.
      def mime(boundary: "CORE#{@payload_id}")
        parts = metadata.merge("Payload" => @payload).map do |name, value|
          "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n#{value}\r\n"
        end
        parts.join + "--#{boundary}--\r\n"
      end

      def mime_content_type(boundary: "CORE#{@payload_id}")
        "multipart/form-data; boundary=#{boundary}"
      end

      # PayloadLength is written for batch only; the rule forbids it in real time.
      def metadata
        fields = FIELDS.zip([@payload_type, @mode, @payload_id, timestamp,
                             @sender, @receiver, RULE_VERSION]).to_h
        batch? ? fields.merge("PayloadLength" => @payload.bytesize.to_s) : fields
      end

      def batch?
        @mode == BATCH
      end

      private

      # The body element name, which the receiver routes on.
      def element
        return "COREEnvelopeRealTimeRequest" unless batch?

        if @payload_type == BATCH_RESULTS
          "COREEnvelopeBatchResultsRetrievalRequest"
        else
          "COREEnvelopeBatchSubmission"
        end
      end

      # WS-Security username/password, used when client certificates are not. Never logged.
      def security
        return "" if @username.nil?

        "<wsse:Security xmlns:wsse=\"#{WSSE}\">" \
          "<wsse:UsernameToken><wsse:Username>#{escape(@username)}</wsse:Username>" \
          "<wsse:Password>#{escape(@password)}</wsse:Password>" \
          "</wsse:UsernameToken></wsse:Security>"
      end

      # UTC, per the rule's dateTime constraint.
      def timestamp
        @now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
      end

      # Escapes XML metacharacters, which names inside a payload can carry.
      def escape(value)
        value.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
    end
  end
end
