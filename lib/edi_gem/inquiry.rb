# frozen_string_literal: true

module EdiGem
  # The question sent to a source: an eligibility check at a known payer, or an insurance
  # discovery that looks for coverage without one.
  module Inquiry
    # Fields shared by both kinds of inquiry.
    class Base
      # Service type 30, general health benefit coverage. Every payer must answer it. Send one
      # code per inquiry: some payers answer only the first of several.
      PLAN_COVERAGE = "30"

      attr_reader :subscriber, :provider, :as_of, :service_type_codes

      def initialize(subscriber:, provider:, as_of: nil, service_type_codes: [PLAN_COVERAGE])
        @subscriber = subscriber
        @provider = provider
        @as_of = as_of
        @service_type_codes = service_type_codes
      end

      # The date asked about, as X12's YYYYMMDD, or nil when none was given.
      def service_date(default: nil)
        date = @as_of || default
        return nil if date.nil?

        date.respond_to?(:strftime) ? date.strftime("%Y%m%d") : date.to_s
      end

      # Whether the subscriber carries every field of at least one of the source's options.
      def satisfies?(search_options)
        search_options.any? { |option| option.all? { |field| @subscriber.public_send(field) } }
      end
    end

    # An eligibility check at a known payer.
    #
    # `payer_code` is the target clearinghouse's code for the payer; codes differ between
    # clearinghouses, so the caller passes the one for the source it is calling. `payer_name` is
    # optional and written only where a source's request carries it (NM1*PR in a 270).
    # `required_credentials` lists the Credential keys the payer requires through that source.
    class Eligibility < Base
      attr_reader :payer_code, :payer_name, :required_credentials

      def initialize(payer_code:, payer_name: nil, required_credentials: [], **base)
        super(**base)
        @payer_code = payer_code
        @payer_name = payer_name
        @required_credentials = required_credentials.map(&:to_sym)
      end
    end

    # An insurance discovery: a search for coverage when the payer is not known.
    #
    # `as_of` is required. A discovery must carry a service date, and the gem does not pick
    # "today" because that depends on the caller's time zone.
    class Discovery < Base
      def initialize(as_of:, **base)
        raise ArgumentError, "as_of is required on a discovery: name the date to ask about" if
          as_of.nil?

        super
      end
    end
  end
end
