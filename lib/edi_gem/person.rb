# frozen_string_literal: true

module EdiGem
  # A person as the payer holds them on its answer: the subscriber (the policyholder) or a
  # dependent on the subscriber's policy.
  #
  # `relationship_code` is X12's: 18 is the subscriber themself; a dependent's is 01 spouse,
  # 19 child, 20 employee, 21 unknown, 39 organ donor, 40 cadaver donor, 53 life partner or G8
  # other. A dependent's member_id is never sent: theirs is the subscriber's. The maintenance
  # codes 001 and 25 say the payer changed identifying information it was sent (CAQH CORE 258
  # returns the name it holds this way). `address` is the one the payer holds, or nil.
  class Person
    include Concealed

    SELF = "18"
    CHANGED = "001"
    IDENTITY_CORRECTED = "25"

    FIELDS = %i[first_name last_name middle_name date_of_birth member_id relationship_code
                maintenance_type_code maintenance_reason_code].freeze
    # The fields a schema reads an address into, by the Address field each fills.
    ADDRESS_FIELDS = { address_line1: :line1, address_line2: :line2, city: :city, state: :state,
                       postal_code: :postal_code }.freeze

    attr_reader(*FIELDS, :role, :address)

    # `role` is :subscriber or :dependent, the part of the answer the person came back in.
    def initialize(role:, **fields)
      @role = role
      FIELDS.each { |field| instance_variable_set(:"@#{field}", fields[field]) }
      @address = Address.from(**ADDRESS_FIELDS.to_h { |from, to| [to, fields[from]] })
    end

    def dependent? = @role == :dependent

    def identity_corrected?
      @maintenance_type_code == CHANGED && @maintenance_reason_code == IDENTITY_CORRECTED
    end

    # What Identity.compare reads.
    def identity
      { first_name: @first_name, last_name: @last_name, date_of_birth: @date_of_birth }
    end

    def concealed_inspect
      set = FIELDS.select { |field| public_send(field) }
      set << :address if @address
      "#<#{self.class} #{@role} #{set.join(",")}>"
    end
  end
end
