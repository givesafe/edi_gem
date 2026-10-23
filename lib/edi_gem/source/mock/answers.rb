# frozen_string_literal: true

require "securerandom"

module EdiGem
  module Source
    class Mock < Stedi
      # The bodies Stedi answers a discovery with, for a Scenario, in Stedi's shapes.
      class Answers
        PENDING = Stedi::Responses::PENDING
        COMPLETE = Stedi::Responses::COMPLETE
        ERROR = Stedi::Responses::ERROR

        # The payers a plan is found at when the caller names none.
        PAYERS = %w[MOCKPAYER].freeze

        # The fields Stedi refuses a discovery without: the provider's NPI and the person's names.
        REQUIRED = [%w[provider npi], %w[subscriber firstName], %w[subscriber lastName]].freeze

        # Codes whose follow-up is not "Please Correct and Resubmit".
        FOLLOWUPS = { "42" => "Resubmission Not Allowed", "80" => "Resubmission Not Allowed",
                      "04" => "Resubmission Not Allowed" }.freeze

        # A pending discovery's id names its scenario, never the person.
        DISCOVERY_ID = /\Amock-([a-z_]+)-/

        # `payers` are the payer codes a discovery finds plans at: a list, or something answering
        # `call` with one, asked on every discovery. `people` finds the person a pending discovery
        # was about by its id (an EdiGem::Subscriber, or nil); without it, the mock remembers the
        # people it was asked about itself, for as long as it lives.
        def initialize(payers: PAYERS, people: nil)
          @payers = payers
          @remembered = {}
          @people = people || @remembered.to_proc
        end

        # The mock's check of a request body against what Stedi requires.
        def self.valid?(body)
          REQUIRED.none? { |path| EdiGem.blank?(body.dig(*path)) }
        end

        # A discovery's answer: pending, ERROR, or COMPLETE with what the scenario finds.
        def discovery(body, scenario)
          subscriber = body.fetch("subscriber")
          name = scenario.name
          return pending(name, subscriber) if scenario.pending?
          return answer(ERROR, [], []) if name == :error

          complete(subscriber, scenario)
        end

        # What collecting a pending discovery finds, or nil for an id Stedi does not keep (an
        # expired one, or one it never gave).
        def resolved(discovery_id)
          case discovery_id.to_s[DISCOVERY_ID, 1]&.to_sym
          when :still_pending then answer(PENDING, [], [], discovery_id)
          when :pending_error then answer(ERROR, [], [], discovery_id)
          when :pending then collected(discovery_id)
          end
        end

        private

        # Reads the person from the request body into the Subscriber it remembers. The envied
        # object is that body's subscriber, a Hash parsed from JSON, which can't take the method.
        # :reek:FeatureEnvy
        def pending(name, subscriber)
          discovery_id = "mock-#{name}-#{SecureRandom.uuid}"
          @remembered[discovery_id] = Subscriber.new(first_name: subscriber["firstName"],
                                                     last_name: subscriber["lastName"],
                                                     date_of_birth: subscriber["dateOfBirth"])
          answer(PENDING, [], [], discovery_id)
        end

        # A pending discovery, found active for the person it was about.
        # Subscriber#to_h is the request's shape, not the one Plans reads: symbol keys, names as
        # Identity.plain spells them, blanks dropped. Using it would change what a collected answer
        # echoes for a person `people` returns, which is a question for the mock's owner.
        # :reek:FeatureEnvy
        def collected(discovery_id)
          person = @people.call(discovery_id)
          return unless person

          subscriber = { "firstName" => person.first_name, "lastName" => person.last_name,
                         "dateOfBirth" => person.date_of_birth }
          complete(subscriber, Scenario.new("active"), discovery_id)
        end

        def complete(subscriber, scenario, discovery_id = new_id)
          name = scenario.name
          body = answer(COMPLETE, found(subscriber, name), errors(scenario), discovery_id)
          body["warnings"] = mock_warnings if name == :confident
          body
        end

        def found(subscriber, name)
          Plans.new(subscriber, payers: payer_codes).for(name).each { |item| item["confidence"] = confidence(name) }
        end

        def mock_warnings = [{ "code" => "MOCK", "description" => "mock warning" }]

        # Stedi labels every discovery "production", whatever the key.
        def answer(status, items, errors, discovery_id = new_id)
          { "meta" => meta, "discoveryId" => discovery_id, "status" => status,
            "coveragesFound" => (items.size unless status == PENDING), "items" => items,
            "errors" => errors }.compact
        end

        def new_id = "mock-#{SecureRandom.uuid}"

        def meta = { "applicationMode" => "production", "traceId" => "mock-#{SecureRandom.hex(6)}" }

        # The mock's payers: a list, or a callable read on every discovery. `payers:` takes both:
        # the documented form is a list, and the app passes a callable (`-> { Deployment.payer_ids }`),
        # so telling them apart stays here, in the one place that reads them.
        # :reek:ManualDispatch
        def payer_codes = @payers.respond_to?(:call) ? @payers.call : @payers

        def confidence(name)
          return { "level" => "HIGH", "reason" => "Name, date of birth and state matched" } if name == :confident

          { "level" => "REVIEW_NEEDED" }
        end

        def errors(scenario)
          code, location = scenario.rejection
          return [] unless code

          [{ "field" => "AAA", "code" => code, "description" => "mock rejection #{code}",
             "followupAction" => FOLLOWUPS.fetch(code, "Please Correct and Resubmit"), "location" => location,
             "possibleResolutions" => "mock" }]
        end
      end
    end
  end
end
