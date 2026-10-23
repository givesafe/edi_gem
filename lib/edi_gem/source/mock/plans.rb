# frozen_string_literal: true

require "date"

module EdiGem
  module Source
    class Mock < Stedi
      # The coverages a scenario finds for one person, as Stedi's items: one per payer, each with
      # its subscriber, payer and benefit lines. Every value is made up. Codes are X12: EB01 1 to 5
      # active and 6 to 8 inactive (5, 7 and 8 pending an investigation or update).
      # One method per scripted plan.
      # :reek:TooManyMethods
      class Plans
        # Scenarios that find one plan at every payer, with this EB01 code.
        EB01_BY_SCENARIO = { active: "1", confident: "1", found_with_error: "1", throttled_once: "1",
                             partial: "1", inactive: "6", active_investigation: "5",
                             inactive_update: "7", inactive_investigation: "8" }.freeze

        # Scenarios whose plans differ from that in some other way, and the method that finds them.
        # Each is the name of the method below that finds them.
        SHAPED = %i[unverified spelled other_person other_payer dependent mixed ended not_started dental
                    medicaid_mco].freeze

        OTHER_PAYER = "MOCKOTHER"
        MEDICAID_PAYER = "MOCKMEDICAID"
        MEDICAID_ID = "MOCKSTATE0001"
        MISMATCHED_BIRTH_DATE = "19000101"

        # Who the patient's policyholder is when the patient is a dependent: neither their first
        # name nor their birth date is the patient's.
        POLICYHOLDER = { "firstName" => "JORDAN", "dateOfBirth" => "19750101" }.freeze

        # Stedi's subscriber is always the policyholder: relationship 18.
        SELF = { "relationToSubscriber" => "Self", "relationToSubscriberCode" => "18" }.freeze
        CHILD = { "relationToSubscriber" => "Child", "relationToSubscriberCode" => "19" }.freeze

        # The address the payer holds for the subscriber, which Stedi sends with each plan it finds.
        ON_RECORD = { "address" => { "address1" => "1 MOCK WAY", "city" => "MOCKVILLE", "state" => "ZZ",
                                     "postalCode" => "00000" } }.freeze

        MEDICAL = ["30"].freeze
        DENTAL = ["35"].freeze

        # `person` is Stedi's subscriber hash as asked about; `payers` the payer codes a plan is
        # found at; `today` what the dated scenarios are dated from.
        def initialize(person, payers:, today: Date.today)
          @person = person
          @payers = payers
          @today = today
        end

        # The items `scenario` finds. Any scenario that finds nothing is an empty list.
        def for(scenario)
          code = EB01_BY_SCENARIO[scenario]
          return each_payer(@person, code) if code
          return [] unless SHAPED.include?(scenario)

          send(scenario)
        end

        private

        def each_payer(person, code, service_types: MEDICAL)
          @payers.map { |payer| item(person, payer, code, service_types: service_types) }
        end

        # Plans that name no birth date, so there is nothing to confirm the person by.
        def unverified = each_payer(@person.except("dateOfBirth"), "1")

        # The person as a payer spells them: plain, and a long first name cut short. Still the
        # person asked about.
        def spelled
          first_name, last_name = @person.values_at("firstName", "lastName").map { |name| Identity.plain(name) }
          person = @person.merge("firstName" => first_name.to_s[0, Identity::TRUNCATED_AT], "lastName" => last_name)
          each_payer(person, "1")
        end

        def other_person
          each_payer(@person.merge("firstName" => "ALEX", "dateOfBirth" => MISMATCHED_BIRTH_DATE), "1")
        end

        def other_payer = [item(@person, OTHER_PAYER, "1")]

        # Stedi puts the patient in `dependent` and the policyholder in `subscriber`.
        def dependent
          patient = @person.slice("firstName", "lastName", "dateOfBirth").merge(CHILD)
          each_payer(@person, "1").map do |found|
            found.merge("subscriber" => found["subscriber"].merge(POLICYHOLDER), "dependent" => patient)
          end
        end

        # An active plan and an inactive one at every payer, under two member IDs.
        def mixed
          @payers.flat_map do |payer|
            [item(@person, payer, "1", member_id: "MOCK#{payer}A"),
             item(@person, payer, "6", member_id: "MOCK#{payer}B")]
          end
        end

        # Active by their code, with plan dates that do not cover today.
        def ended = dated(@today << 24, @today << 1)

        def not_started = dated(@today >> 1, @today >> 24)

        def dated(begins, ends)
          each_payer(@person, "1").each do |found|
            found["planDateInformation"] = { "planBegin" => Codec.yyyymmdd(begins),
                                             "planEnd" => Codec.yyyymmdd(ends) }
          end
        end

        def dental = each_payer(@person, "1", service_types: DENTAL)

        # A Medicaid MCO naming the state's Medicaid as its primary payer, and the state's own item.
        def medicaid_mco
          primary = { "entityIdentifier" => "Primary Payer", "entityType" => "Non-Person Entity",
                      "entityName" => "MOCK MEDICAID", "entityIdentification" => "PI",
                      "entityIdentificationValue" => MEDICAID_PAYER }
          mco_items = each_payer(@person, "1").each { |found| name_primary_payer(found, primary) }
          medicaid = item(@person, MEDICAID_PAYER, "1", member_id: MEDICAID_ID)
          medicaid["planInformation"] = { "medicaidRecipientIdNumber" => MEDICAID_ID }
          mco_items + [medicaid]
        end

        def name_primary_payer(found, primary)
          found["benefitsInformation"].each { |line| line["benefitsRelatedEntities"] = [primary] }
        end

        # `name` is the status's label; the plan's own name is in `planCoverage`, as Stedi sends it.
        def item(person, payer, code, member_id: "MOCK#{payer}", service_types: MEDICAL)
          { "subscriber" => person.slice("firstName", "lastName", "dateOfBirth")
                                  .merge("memberId" => member_id, **SELF, **ON_RECORD),
            "payer" => { "name" => "MOCK PAYER #{payer}", "payorIdentification" => payer },
            "benefitsInformation" => [{ "code" => code, "name" => code.to_i <= 5 ? "Active Coverage" : "Inactive",
                                        "serviceTypeCodes" => service_types, "insuranceType" => "MC",
                                        "planCoverage" => "MOCK PLAN #{payer}" }] }
        end
      end
    end
  end
end
