# frozen_string_literal: true

module EdiGem
  module Source
    class Stedi < Base
      # The JSON bodies Stedi is sent, built from an Inquiry without sending anything.
      class Request
        # Credential keys a payer may require, and the top-level body field each is sent as.
        CREDENTIAL_FIELDS = { portal_password: :portalPassword,
                              portal_username: :portalUsername }.freeze

        # The question a discovery body (#discovery, parsed) asked, as an Inquiry::Question: the
        # subscriber's names as they were sent (Identity.plain), birth date, address and SSN, of
        # which the person keeps the last four only, and the first day of service. A birth date
        # that is not a YYYYMMDD string naming a real day (a number included) is nil. Raises
        # UnreadableBody when the body holds no subscriber, or no day of service as such a string,
        # since it is then not a discovery request.
        def self.question(body)
          subscriber = body["subscriber"] if body.is_a?(Hash)
          encounter = body["encounter"] if subscriber.is_a?(Hash)
          on = encounter["beginningDateOfService"] if encounter.is_a?(Hash)
          raise UnreadableBody, "the body is not a discovery request" unless on.is_a?(String) && on.match?(Codec::DAY)

          Inquiry::Question.new(person: asked_person(subscriber), as_of: Date.strptime(on, "%Y%m%d"))
        rescue Date::Error
          raise UnreadableBody, "the body's day of service is not a date"
        end

        def self.asked_person(subscriber)
          Person::Asked.new(first_name: subscriber["firstName"], last_name: subscriber["lastName"],
                            date_of_birth: born_on(subscriber["dateOfBirth"]),
                            address: Address.from_stedi(subscriber["address"]), ssn: subscriber["ssn"])
        end
        private_class_method :asked_person

        def self.born_on(day)
          Date.strptime(day, "%Y%m%d") if day.is_a?(String) && day.match?(Codec::DAY)
        rescue Date::Error
          nil
        end
        private_class_method :born_on

        # `policy` says what the payer needs through Stedi; the inquiry may name more.
        def initialize(inquiry, policy:, payer_code: nil, credential: nil)
          @inquiry = inquiry
          @payer_code = payer_code
          @credential = credential
          @policy = policy
        end

        # dateOfService is sent only when the inquiry names a date; omitting it asks about today.
        # A dependent goes in `dependents`, one per check.
        def eligibility
          encounter = { serviceTypeCodes: @inquiry.service_type_codes }
          encounter[:dateOfService] = @inquiry.service_date if @inquiry.as_of
          body = { tradingPartnerServiceId: @payer_code,
                   provider: @inquiry.provider.to_h,
                   subscriber: @inquiry.subscriber.to_h }
          body[:dependents] = [@inquiry.dependent.to_dependent_h] if @inquiry.dependent?
          body.merge(encounter: encounter).merge(credentials)
        end

        # One batch item: the eligibility body plus the identifier its answer comes back under.
        def batch_item(identifier)
          eligibility.merge(submitterTransactionIdentifier: identifier.to_s)
        end

        # A discovery must carry a service date range; Inquiry::Discovery requires as_of.
        def discovery
          on = @inquiry.service_date
          { provider: @inquiry.provider.to_h, subscriber: @inquiry.subscriber.to_h,
            encounter: { beginningDateOfService: on, endDateOfService: on,
                         serviceTypeCodes: @inquiry.service_type_codes } }
        end

        private

        def required_credentials
          @policy.credentials_for(@payer_code) | @inquiry.required_credentials
        end

        def credentials
          (@inquiry.credential || @credential || Credential.none)
            .values_for(required_credentials, CREDENTIAL_FIELDS,
                        payer: @inquiry.payer_name || @payer_code)
        end
      end
    end
  end
end
