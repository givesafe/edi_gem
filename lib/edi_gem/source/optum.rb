# frozen_string_literal: true

module EdiGem
  module Source
    # Optum real-time eligibility, as bare X12 270/271.
    #
    # Written from Optum's published real-time eligibility documentation. It has never been
    # called against the live service, and no trading partner agreement is held. The endpoint,
    # envelope form and authentication are unconfirmed; the endpoint and receiver id must come
    # from the Credential.
    class Optum < X12Source
      NAME = :optum

      # No published default receiver id; it must come from the credential.
      RECEIVER = nil
      DIALECT = :x12
      USAGE = X12::Interchange::TEST

      # The X12 5010 primary search options.
      SEARCH_OPTIONS = [%i[member_id last_name date_of_birth],
                        %i[member_id first_name last_name date_of_birth],
                        %i[first_name last_name date_of_birth ssn]].freeze

      def search_options
        SEARCH_OPTIONS
      end

      private

      def headers
        { "Content-Type" => "application/edi-x12" }
      end

      def request_body(inquiry, trace:)
        interchange.wrap(transaction(inquiry, trace: trace).segments)
      end
    end
  end
end
