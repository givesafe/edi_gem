# frozen_string_literal: true

module EdiGem
  # The person being asked about. Every field is optional: which combination is required is
  # each source's search_options, checked by Inquiry#satisfies?.
  class Subscriber
    # date_of_birth is X12's YYYYMMDD, not an ISO date.
    attr_reader :member_id, :first_name, :last_name, :middle_name, :date_of_birth,
                :gender, :ssn, :group_number, :relationship

    # `relationship` is the X12 subscriber relationship; :self means the patient is the
    # subscriber.
    def initialize(member_id: nil, first_name: nil, last_name: nil, middle_name: nil,
                   date_of_birth: nil, gender: nil, ssn: nil, group_number: nil,
                   relationship: :self)
      @member_id = member_id
      @first_name = first_name
      @last_name = last_name
      @middle_name = middle_name
      @date_of_birth = date_of_birth
      @gender = gender
      @ssn = ssn
      @group_number = group_number
      @relationship = relationship
    end

    RELATIONSHIP_CODES = { self: "18", spouse: "01", child: "19", other: "G8" }.freeze

    # The fields a source's search_options are written in terms of.
    SEARCHABLE = %i[member_id first_name last_name middle_name date_of_birth gender ssn
                    group_number].freeze

    # The names of the fields this subscriber carries, never their values.
    def identifiers
      SEARCHABLE.select { |field| public_send(field) }
    end

    def to_h
      { memberId: @member_id, firstName: @first_name, lastName: @last_name,
        dateOfBirth: @date_of_birth, gender: @gender, ssn: @ssn,
        groupNumber: @group_number }.compact
    end

    # Names and identifiers are PHI, so only which fields are set is printed.
    def inspect
      "#<#{self.class} #{to_h.keys.join(",")}>"
    end
  end
end
