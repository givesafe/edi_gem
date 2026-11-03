# frozen_string_literal: true

module EdiGem
  module Source
    class Stedi < Base
      # The JSON bodies Stedi is sent, built from an Inquiry without sending anything.
      class Request
        # Credential keys a payer may require, and the top-level body field each is sent as.
        CREDENTIAL_FIELDS = { portal_password: :portalPassword,
                              portal_username: :portalUsername }.freeze

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
