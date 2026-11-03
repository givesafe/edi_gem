# frozen_string_literal: true

module EdiGem
  module X12
    class Transaction270
      # The people a 270 asks about: 2000C/2100C the subscriber and, when the patient is on their
      # policy, 2000D/2100D the dependent. The patient's level carries the trace, the plan date and
      # the service types.
      module People
        private

        # 2000C/2100C: the subscriber. When they are the patient, the trace, dates and service
        # types asked about are theirs; otherwise they belong to the dependent below.
        def subscriber
          person = @inquiry.subscriber
          return [segment("HL", "3", "2", SUBSCRIBER_LEVEL, HAS_CHILDREN), named(person, SUBSCRIBER)] if
            @inquiry.dependent?

          [segment("HL", "3", "2", SUBSCRIBER_LEVEL, NO_CHILDREN), *patient(person, SUBSCRIBER)]
        end

        # 2000D/2100D: the dependent, under the subscriber, with INS02 their relationship when known.
        def dependent
          return [] unless @inquiry.dependent?

          [segment("HL", "4", "3", DEPENDENT_LEVEL, NO_CHILDREN), *patient(@inquiry.dependent, DEPENDENT)]
        end

        def patient(person, entity)
          relationship = (person.dependent_relationship_code if entity == DEPENDENT)
          [segment("TRN", TRACE_ASSIGNED_HERE, @trace, originator),
           named(person, entity),
           *optional("REF", "SY", person.ssn),
           *demographics(person),
           *optional("INS", NOT_INSURED, relationship),
           *plan_date,
           segment("EQ", @inquiry.service_type_codes.join(":"))]
        end

        # X12 writes the last name first (NM103) and a suffix apart (NM107). Names go as
        # Identity spells them for a payer, without titles.
        def named(person, entity)
          last_name, suffix = Identity.payer_sent_last_name(person.last_name)
          segment("NM1", entity, PERSON, last_name.to_s, Identity.payer_sent(person.first_name).to_s,
                  Identity.payer_sent(person.middle_name).to_s, "", suffix.to_s, *member_id(person))
        end

        # DMG is omitted rather than sent without a birth date.
        def demographics(person)
          return [] if person.date_of_birth.nil?

          [segment("DMG", SINGLE_DATE, person.date_of_birth, person.gender.to_s)]
        end

        def member_id(person)
          person.member_id ? [MEMBER_ID, person.member_id] : []
        end
      end
    end
  end
end
