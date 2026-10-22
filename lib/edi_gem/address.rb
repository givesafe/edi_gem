# frozen_string_literal: true

module EdiGem
  # A postal address: one a person is asked about with, or the one a payer holds on record. Every
  # field is optional.
  class Address
    include Concealed

    FIELDS = %i[line1 line2 city state postal_code].freeze

    attr_reader(*FIELDS)

    # nil when no field holds a value, so an address is never an empty one.
    def self.from(**fields)
      new(**fields) unless fields.values_at(*FIELDS).all? { |value| value.nil? || value.to_s.empty? }
    end

    def initialize(line1: nil, line2: nil, city: nil, state: nil, postal_code: nil)
      @line1 = line1
      @line2 = line2
      @city = city
      @state = state
      @postal_code = postal_code
    end

    def to_h
      FIELDS.to_h { |field| [field, public_send(field)] }.compact
    end

    # As Stedi takes and returns one.
    def to_stedi_h
      { address1: @line1, address2: @line2, city: @city, state: @state, postalCode: @postal_code }.compact
    end

    def concealed_inspect
      "#<#{self.class} #{to_h.keys.join(",")}>"
    end
  end
end
