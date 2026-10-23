# frozen_string_literal: true

module EdiGem
  # The question sent to a source: an eligibility check at a known payer, or an insurance
  # discovery that looks for coverage without one.
  module Inquiry
    # What a discovery asked: who (`person`, a Person::Asked carrying any address and last four
    # given beside the core) and the day it asked about (`as_of`, a Date). An answer is compared
    # with it whether the answer came at once or was collected later (Response#medical_plans'
    # `asked:` takes `person`), so a later change to the caller's record never changes it.
    # Built by Discovery#question, or recovered from an archived request (Source's
    # archived_question).
    Question = Struct.new(:person, :as_of, keyword_init: true)

    # Fields shared by both kinds of inquiry.
    class Base
      # Service type 30, general health benefit coverage. Every payer must answer it. Send one
      # code per inquiry: some payers answer only the first of several.
      PLAN_COVERAGE = "30"

      attr_reader :subscriber, :dependent, :provider, :as_of, :service_type_codes

      # `dependent` is the patient when they are on the subscriber's policy and the payer cannot
      # identify them on their own: `subscriber` then carries the policy's member id, and
      # `dependent` the patient's names and birth date. Someone with their own member id, even one
      # that differs from the family's by a suffix, is asked about as the subscriber.
      def initialize(subscriber:, provider:, as_of: nil, service_type_codes: [PLAN_COVERAGE],
                     dependent: nil)
        @subscriber = subscriber
        @dependent = dependent
        @provider = provider
        @as_of = as_of
        @service_type_codes = service_type_codes
      end

      # The date asked about, as X12's YYYYMMDD, or nil when none was given.
      def service_date(default: nil)
        Codec.yyyymmdd(@as_of || default)
      end

      def dependent? = !@dependent.nil?

      # The person asked about: the dependent when there is one.
      def patient = @dependent || @subscriber

      # Whether the inquiry carries every field of at least one of the source's options. With a
      # dependent, the member id is the subscriber's and the rest the dependent's.
      def satisfies?(search_options)
        search_options.any? { |option| option.all? { |field| searched(field) } }
      end

      # Stedi's Idempotency-Key for this inquiry on the caller's day `on` (see RequestKey). `routing`
      # is what the kind of inquiry needs to say what it asks (a check's clearinghouse).
      def idempotency_key(secret:, on:, **routing)
        RequestKey.idempotency_key(self.class::OPERATION, asked_on_a_day(**routing), secret: secret, on: on)
      end

      # What this inquiry asks, on any day (see RequestKey).
      def fingerprint(secret:, **routing) = RequestKey.fingerprint(asked(**routing), secret: secret)

      private

      # What a day's key is made from: what the inquiry asks, unless a kind adds to it.
      def asked_on_a_day(**routing) = asked(**routing)

      # The patient's birth date as a Date, so a key made from it matches one made from a Date.
      def birth_date = Codec.day(patient.date_of_birth)

      def searched(field)
        return @subscriber.public_send(field) if @dependent.nil? || field == :member_id

        @dependent.public_send(field)
      end
    end

    # An eligibility check at a known payer.
    #
    # `payer_code` is the target clearinghouse's code for the payer; codes differ between
    # clearinghouses, so the caller passes the one for the source it is calling. `payer_name` is
    # optional and written only where a source's request carries it (NM1*PR in a 270).
    # `required_credentials` lists Credential keys the payer requires through that source, beyond
    # those the source already knows it needs. `credential` holds this payer's secrets for this
    # inquiry, and is used in place of the source's own: each payer issues its own.
    class Eligibility < Base
      OPERATION = :eligibility

      attr_reader :payer_code, :payer_name, :required_credentials, :credential

      def initialize(payer_code:, payer_name: nil, required_credentials: [], credential: nil, **base)
        super(**base)
        @payer_code = payer_code
        @payer_name = payer_name
        @required_credentials = required_credentials.map(&:to_sym)
        @credential = credential
      end

      private

      def asked_as = dependent? ? :dependent : :subscriber

      # A check's keys take `clearinghouse:`, the source it is sent through, since the payer code
      # is that source's. Its fingerprint is the same asked either way; a day's key is not: asked
      # as the subscriber or as a dependent, the two are different questions.
      def asked_on_a_day(clearinghouse:) = asked(clearinghouse: clearinghouse).merge(asked_as: asked_as)

      # The patient's names as the payer is sent them, so any spelling sent the same way is the
      # same question; the member id is the subscriber's.
      def asked(clearinghouse:)
        { first_name: Identity.plain(patient.first_name), last_name: Identity.plain(patient.last_name),
          date_of_birth: birth_date, insurance_id: @subscriber.member_id, payer_id: @payer_code,
          payer_type: clearinghouse }
      end
    end

    # An insurance discovery: a search for coverage when the payer is not known.
    #
    # `as_of` is required. A discovery must carry a service date, and the gem does not pick
    # "today" because that depends on the caller's time zone.
    class Discovery < Base
      OPERATION = :discovery

      def initialize(as_of:, **base)
        raise ArgumentError, "as_of is required on a discovery: name the date to ask about" if
          as_of.nil?
        if base[:dependent]
          raise ArgumentError, "a discovery cannot ask about a dependent: send the patient as " \
                               "the subscriber"
        end

        super
      end

      # What this discovery asks (a Question): the subscriber as given, with the address and SSN
      # it carries, of which the person keeps the last four only, and the day as a Date.
      def question
        Question.new(person: Person::Asked.new(first_name: @subscriber.first_name, last_name: @subscriber.last_name,
                                               date_of_birth: birth_date, address: @subscriber.address,
                                               ssn: @subscriber.ssn),
                     as_of: Codec.day(service_date))
      end

      private

      # The names as given, not as sent. The SSN, the address's first line and its postal code
      # make two discoveries of one person different questions.
      def asked
        address = @subscriber.address
        { first_name: @subscriber.first_name, last_name: @subscriber.last_name, date_of_birth: birth_date,
          ssn: @subscriber.ssn, address_line1: address&.line1, postal_code: address&.postal_code }
      end
    end
  end
end
