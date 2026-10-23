# frozen_string_literal: true

module EdiGem
  module Source
    class Mock < Stedi
      # What the mock answers, picked by the person's last name: a name in NAMES, or "Aaa" and a
      # code for any AAA rejection Stedi publishes. Case, spaces and punctuation are ignored, so
      # "Active", "ACTIVE" and " ac-tive" are one scenario. Any other last name finds no coverage.
      class Scenario
        NAMES = {
          # Found, with coverage
          "active" => :active, "inactive" => :inactive, "unverified" => :unverified, "spelled" => :spelled,
          "otherperson" => :other_person, "otherpayer" => :other_payer, "dependent" => :dependent,
          "mixed" => :mixed, "ended" => :ended, "notstarted" => :not_started,
          "activeinvestigation" => :active_investigation, "inactiveupdate" => :inactive_update,
          "inactiveinvestigation" => :inactive_investigation, "dental" => :dental,
          "medicaidmco" => :medicaid_mco, "confident" => :confident, "foundwitherror" => :found_with_error,
          "partial" => :partial,
          # An AAA rejection and no coverage
          "refused" => :refused, "noanswer" => :no_answer, "notfound" => :not_found,
          # A discovery Stedi could not complete (status ERROR)
          "error" => :error,
          # A pending discovery (HTTP 202), then what collecting it finds
          "pending" => :pending, "stillpending" => :still_pending, "pendingerror" => :pending_error,
          "expired" => :expired,
          # HTTP failures, as the Transport meets them
          "invalid" => :invalid, "forbidden" => :forbidden, "inflight" => :in_flight,
          "keyreused" => :key_reused, "throttled" => :throttled, "throttledonce" => :throttled_once,
          "servererror" => :server_error, "unavailable" => :unavailable,
          "gatewaytimeout" => :gateway_timeout, "timeout" => :timeout
        }.freeze

        # The scenario any other last name is: answered, with no coverage.
        NOT_COVERED = :not_covered

        # The scenarios a discovery answers asynchronously.
        PENDING = %i[pending still_pending pending_error expired].freeze

        # "Aaa75", "AAA 43": that AAA03 code.
        AAA_NAME = /\Aaaa([0-9a-z]{2})\z/

        # Every AAA03 code Stedi publishes (its OpenAPI), each in the first X12 loop it is valid in, in
        # the order subscriber, dependent, provider, payer.
        AAA_LANES = {
          "Loop 2100C" => %w[15 33 35 42 43 45 47 48 49 51 52 53 54 55 56 57 58 60 61 62 63 69 70 71 72 73
                             74 75 76 78 98 AA AE AF AG AO CI E8 IA MA],
          "Loop 2100D" => %w[64 65 66 67 68 77],
          "Loop 2100B" => %w[41 44 46 50 79 97 T4],
          "Loop 2100A" => %w[04 80]
        }.freeze

        # The rejection each named scenario answers with: its AAA03 code and the loop it is in.
        REJECTIONS = { refused: ["43", "Loop 2100B"], no_answer: ["42", "Loop 2100A"],
                       found_with_error: ["42", "Loop 2100A"], not_found: ["75", "Loop 2100C"],
                       partial: ["15", "Loop 2100C"] }.freeze

        def initialize(last_name)
          @key = last_name.to_s.downcase.delete("^a-z0-9")
        end

        def name
          return :aaa if aaa_code

          NAMES.fetch(@key, NOT_COVERED)
        end

        def pending? = PENDING.include?(name)

        # The AAA03 code and loop this scenario is rejected with, or nil when it is not.
        def rejection
          return [aaa_code, aaa_location] if aaa_code

          REJECTIONS[name]
        end

        private

        # The code an "Aaa" last name asks for, when Stedi publishes it.
        def aaa_code
          code = @key[AAA_NAME, 1]&.upcase
          code if AAA_LANES.values.flatten.include?(code)
        end

        def aaa_location
          AAA_LANES.find { |_location, codes| codes.include?(aaa_code) }.first
        end
      end
    end
  end
end
