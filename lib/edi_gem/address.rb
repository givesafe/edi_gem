# frozen_string_literal: true

module EdiGem
  # A postal address: one a person is asked about with, or the one a payer holds on record. Every
  # field is optional.
  class Address
    include Concealed

    FIELDS = %i[line1 line2 city state postal_code].freeze
    ZIP_DIGITS = 5

    attr_reader(*FIELDS)

    # nil when no field holds a value, so an address is never an empty one.
    def self.from(**fields)
      new(**fields) unless fields.values_at(*FIELDS).all? { |value| EdiGem.blank?(value) }
    end

    # One as Stedi sends it (address1, address2, city, state, postalCode), or nil.
    def self.from_stedi(fields)
      return unless fields.is_a?(Hash)

      from(line1: fields["address1"], line2: fields["address2"], city: fields["city"], state: fields["state"],
           postal_code: fields["postalCode"])
    end

    def initialize(line1: nil, line2: nil, city: nil, state: nil, postal_code: nil)
      @line1 = line1
      @line2 = line2
      @city = city
      @state = state
      @postal_code = postal_code
    end

    # How this address (the one asked with) compares with `other` (the one a payer holds, or
    # nil). A proposed rule (O-20): two parts are compared, the first line by its words as
    # Identity.words reads them (case and punctuation aside), and the postal code's first five
    # digits (a ZIP+4's last four aside). A second line, the city and the state are not compared,
    # and an abbreviation differs from the word it stands for (ST is not STREET).
    #   :matched       both parts agree
    #   :differs       either part disagrees
    #   :not_compared  this address lacks a first line or five postal digits: nothing of ours to compare
    #   :not_returned  ours has both, and the payer holds no address or lacks either part
    # Compares the two forms it built.
    # :reek:FeatureEnvy
    def compare(other)
      mine = comparable
      return :not_compared if mine.nil?

      theirs = other&.comparable
      return :not_returned if theirs.nil?

      mine == theirs ? :matched : :differs
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

    protected

    # The first line's words and the postal code's first five digits, or nil without both.
    def comparable
      words = Identity.words(@line1)
      zip = @postal_code.to_s.scan(/\d/).first(ZIP_DIGITS).join
      [words, zip] unless words.empty? || zip.length < ZIP_DIGITS
    end
  end
end
