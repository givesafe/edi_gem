# frozen_string_literal: true

module EdiGem
  module Source
    # A source asked with a 270 and answering with a 271. Holds the whole eligibility path:
    # write the 270, wrap it in an interchange, send it, read the 271.
    #
    # A subclass supplies NAME, RECEIVER, USAGE, DIALECT, search_options, its HTTP headers and
    # `request_body`. Sending requires the envelope identifiers and endpoint the clearinghouse
    # assigns at enrolment, carried on the Credential.
    class X12Source < Base
      # The interchange identifiers a clearinghouse assigns at enrolment.
      ENVELOPE_FIELDS = %i[sender_id receiver_id application_sender application_receiver].freeze
      ENDPOINT = :endpoint

      DIALECT = :x12
      SCHEMA = :x12_271

      def initialize(credential:, policy: nil, endpoint: nil, transport: nil, client: nil,
                     now: nil)
        super()
        @credential = credential || Credential.none
        @endpoint = endpoint || @credential[ENDPOINT]
        @policy = (policy || Policy.for(self.class::NAME)).at(@endpoint)
        @injected_transport = transport
        @injected_client = client
        @now = now
      end

      def capabilities = { eligibility: true, discovery: false, batch: false }

      # `trace` (TRN02) is what the 271 echoes back; it defaults to one derived from the request,
      # so a retry asks the same question. X12 sources do not archive bodies, so `archive:` is
      # refused rather than ignored.
      def eligibility(inquiry, idempotency_key: nil, archive: nil, trace: nil)
        refuse_archive(archive)
        ensure_searchable(inquiry)
        ensure_enrolled
        number = trace || trace_for(inquiry)
        exchange = connection.post(:eligibility, request_body(inquiry, trace: number),
                                   idempotency_key: idempotency_key)
        read(exchange, trace: number)
      end

      # The 270 for an inquiry, built without sending anything.
      def transaction(inquiry, trace: nil)
        number = trace || trace_for(inquiry)
        X12::Transaction270.new(inquiry, payer_code: payer_code_for(inquiry),
                                         payer_name: inquiry.payer_name.to_s, trace: number,
                                         submitter_id: @credential[:submitter_id] || number,
                                         originator: @credential[:originator], now: @now)
      end

      # One 270 per inquiry, renumbered for a single interchange, each with its own trace.
      def batch_transactions(inquiries)
        inquiries.each_with_index.map do |inquiry, index|
          renumbered(transaction(inquiry, trace: trace_for(inquiry)).segments, index + 1)
        end
      end

      # ST02 must be unique within the group and SE02 must repeat it.
      def renumbered(segments, number)
        control = format("%<n>04d", n: number)
        segments.map do |segment|
          segment.sub(/\A(ST\*270)\*\d+/, "\\1*#{control}")
                 .sub(/\A(SE\*\d+)\*\d+/, "\\1*#{control}")
        end
      end

      def interchange(usage: nil)
        envelope = ENVELOPE_FIELDS.to_h { |field| [field, @credential[field]] }
        X12::Interchange.new(sender: envelope[:sender_id],
                             receiver: envelope[:receiver_id] || self.class::RECEIVER,
                             application_sender: envelope[:application_sender],
                             application_receiver: envelope[:application_receiver] ||
                                                   self.class::RECEIVER,
                             control_number: control_number,
                             usage: usage || self.class::USAGE, now: @now)
      end

      # Splits a file of several 271s into one Document per transaction, so two people's
      # coverage is never read as one. Each piece keeps the file's ISA verbatim, because the
      # reader takes the delimiters from it by offset.
      def split_transactions(body)
        text = body.to_s
        prefix = text[0, Document::X12::ISA_LENGTH].to_s
        opener = "ST#{prefix[Document::X12::ELEMENT_SEPARATOR_OFFSET]}271"
        text.split(opener).drop(1).map { |rest| Document::X12.new(prefix + opener + rest) }
      end

      private

      def refuse_archive(archive)
        return if archive.nil?

        raise FeatureNotSupported, "#{self.class::NAME} does not archive bodies; pass archive: nil"
      end

      # Without enrolment a source refuses every request in a way that looks like a rejected
      # subscriber, so the missing paperwork is reported before sending.
      def ensure_enrolled
        missing = ENVELOPE_FIELDS.reject { |field| @credential[field] }
        if missing.any?
          raise CredentialMissing, "#{self.class::NAME} assigns #{missing.join(", ")} at " \
                                   "enrolment and the credential does not hold them"
        end
        return unless @endpoint.nil?

        raise CredentialMissing,
              "#{self.class::NAME} needs the endpoint it assigns at enrolment"
      end

      def read(exchange, trace:)
        payload = Payload.new(body: exchange.response_body, dialect: self.class::DIALECT)
        reading = Reading.new(document: payload.document, schema: Schema.fetch(SCHEMA))
        Response.new(benefits: reading.benefits,
                     rejections: envelope_rejections(payload.document) + reading.rejections,
                     details: reading.details.merge(trace_id: trace), people: reading.people,
                     payload: payload, exchanges: [exchange], settled: true)
      end

      # A CORE envelope error or a 999 carries no AAA. Without this either would read as a 271
      # with no coverage.
      def envelope_rejections(document)
        refused = document.is_a?(Document::Envelope) && document.error?
        return X12::Acknowledgement.new(document).rejections unless refused

        [Rejection.new(level: :envelope, code: document.metadata["ErrorCode"],
                       description: document.metadata["ErrorMessage"])]
      end

      # Derived from the request so a retry is the same question. Nine characters, because some
      # payers echo TRN02 into shorter fields.
      def trace_for(inquiry)
        Digest::SHA256.hexdigest(JSON.generate(inquiry.subscriber.to_h))[0, 9].upcase
      end

      def control_number
        @credential[:control_number] || Time.now.to_i.to_s[-9..]
      end

      def connection
        @connection ||= Connection.new(policy: @policy, headers: headers,
                                       transport: @injected_transport, client: @injected_client)
      end
    end
  end
end
