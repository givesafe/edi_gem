# frozen_string_literal: true

module EdiGem
  # The person being asked about. Every field is optional: which combination is required is
  # each source's search_options, checked by Inquiry#satisfies?.
  class Subscriber
    include Concealed

    # date_of_birth is X12's YYYYMMDD, not an ISO date.
    attr_reader :member_id, :first_name, :last_name, :middle_name, :date_of_birth,
                :gender, :ssn, :group_number, :relationship, :address

    # `relationship` is the X12 subscriber relationship; :self means the patient is the
    # subscriber. A dependent's is :spouse, :child, :other_adult, or nil when not known (it is
    # then not sent). `address` is an Address, sent to Stedi only; an X12 source does not send it.
    def initialize(member_id: nil, first_name: nil, last_name: nil, middle_name: nil,
                   date_of_birth: nil, gender: nil, ssn: nil, group_number: nil,
                   relationship: :self, address: nil)
      @member_id = member_id
      @first_name = first_name
      @last_name = last_name
      @middle_name = middle_name
      @date_of_birth = date_of_birth
      @gender = gender
      @ssn = ssn
      @group_number = group_number
      @relationship = relationship
      @address = address
    end

    RELATIONSHIP_CODES = { self: "18", spouse: "01", child: "19", other: "G8",
                           other_adult: "34" }.freeze

    # The relationships a 270 can name for a dependent (2100D INS02, Stedi's
    # individualRelationshipCode).
    DEPENDENT_RELATIONSHIPS = %i[spouse child other_adult].freeze

    # The fields a source's search_options are written in terms of.
    SEARCHABLE = %i[member_id first_name last_name middle_name date_of_birth gender ssn
                    group_number].freeze

    # The names of the fields this subscriber carries, never their values.
    def identifiers
      SEARCHABLE.select { |field| public_send(field) }
    end

    # Names go as Identity spells them for a payer: payers differ on accents, so none are sent, and
    # titles aren't either. A suffix goes in Stedi's suffix field, not the last name.
    def to_h
      last_name, suffix = Identity.payer_sent_last_name(@last_name)
      { memberId: @member_id, firstName: Identity.payer_sent(@first_name), lastName: last_name,
        suffix: suffix, dateOfBirth: @date_of_birth, gender: @gender, ssn: @ssn,
        groupNumber: @group_number, address: @address&.to_stedi_h }.compact
    end

    # The X12 code for a dependent's relationship, or nil when it is not one a 270 can name.
    def dependent_relationship_code
      RELATIONSHIP_CODES[@relationship] if DEPENDENT_RELATIONSHIPS.include?(@relationship)
    end

    # As Stedi takes a dependent: no member id (theirs is the subscriber's), and the relationship
    # when known.
    def to_dependent_h
      to_h.except(:memberId, :groupNumber)
          .merge(individualRelationshipCode: dependent_relationship_code).compact
    end

    # Names and identifiers are PHI, so only which fields are set is printed.
    def concealed_inspect
      "#<#{self.class} #{to_h.keys.join(",")}>"
    end
  end
end
