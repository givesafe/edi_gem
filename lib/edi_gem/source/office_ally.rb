# frozen_string_literal: true

module EdiGem
  module Source
    # Office Ally real-time eligibility, X12 270/271 inside a CAQH CORE SOAP envelope.
    #
    # Written from Office Ally's published 270/271 companion guide. It has never been called
    # against the live service, and no trading partner agreement is held. The endpoint and
    # envelope identifiers arrive with that agreement, on the Credential.
    class OfficeAlly < X12Source
      NAME = :office_ally
      RECEIVER = "OFFALLY"
      DIALECT = :soap

      # Every interchange is a test interchange unless the caller asks for production.
      USAGE = X12::Interchange::TEST

      # The guide's minimum search: member id, last name and date of birth.
      SEARCH_OPTIONS = [%i[member_id last_name date_of_birth]].freeze

      def search_options
        SEARCH_OPTIONS
      end

      # CORE batch envelopes, built without sending. Outside the common batch contract (CORE has
      # no batch status call), so `capabilities[:batch]` stays false.
      #
      # The submission: one interchange holding every inquiry. PayloadLength is set here and
      # never on a real-time request.
      def batch_submission(inquiries)
        envelope(interchange.wrap(batch_transactions(inquiries)),
                 payload_type: Core::Request::BATCH_SUBMISSION, mode: Core::Request::BATCH)
      end

      # The retrieval of a submitted batch's 271s, by the submission's payload id.
      def batch_results(payload_id)
        envelope("", payload_type: Core::Request::BATCH_RESULTS, mode: Core::Request::BATCH,
                     payload_id: payload_id)
      end

      # One Response per 271 in a retrieved batch file, in the file's order.
      def read_batch(body)
        split_transactions(body).map do |document|
          reading = Reading.new(document: document, schema: Schema.fetch(SCHEMA))
          Response.new(benefits: reading.benefits, rejections: reading.rejections, people: reading.people,
                       details: reading.details, settled: true)
        end
      end

      private

      # Authentication is the client certificate, so no auth header.
      def headers
        { "Content-Type" => "text/xml; charset=utf-8" }
      end

      def request_body(inquiry, trace:)
        envelope(interchange.wrap(transaction(inquiry, trace: trace).segments)).soap
      end

      def envelope(payload, **options)
        Core::Request.new(payload: payload, sender: @credential[:sender_id], receiver: RECEIVER,
                          username: @credential[:username], password: @credential[:password],
                          now: @now, **options)
      end
    end
  end
end
