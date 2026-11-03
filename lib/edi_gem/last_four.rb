# frozen_string_literal: true

module EdiGem
  # The last four digits of a Social Security number, the one a payer returned. The rest of the
  # number is never kept. Only a comparison leaves this object: no reader returns the digits, and
  # it prints none of them, with EdiGem.reveal on or off, so a revealed Person holding one prints
  # none either.
  #
  # Payers fill the SSN inconsistently, some masked (XXX-XX-1234). Hyphens and spaces are
  # dropped; the four characters left at the end must all be digits to be compared.
  class LastFour
    SEPARATORS = "- "
    DIGITS = /\A\d{4}\z/
    PRINTED = "#<EdiGem::LastFour>"

    # nil when nothing was given (nil or blank); otherwise the last four, readable or not.
    def self.of(ssn)
      new(ssn) unless EdiGem.blank?(ssn)
    end

    def initialize(ssn)
      last = ssn.to_s.delete(SEPARATORS)[-4..]
      @digits = last if last.to_s.match?(DIGITS)
      freeze
    end

    # Whether four digits could be read.
    def readable? = !@digits.nil?

    # Two hold the same last four, or neither holds four readable digits. There is no #hash made
    # from the digits, since it would give them away.
    def ==(other) = other.instance_of?(self.class) && other.same_digits?(@digits)

    def inspect = PRINTED
    def to_s = PRINTED

    # Ruby's pretty_print protocol, so `pp` never prints the digits.
    # :reek:UtilityFunction
    def pretty_print(printer)
      printer.text(PRINTED)
    end

    protected

    def same_digits?(digits) = @digits == digits
  end
end
