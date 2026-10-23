# frozen_string_literal: true

module EdiGem
  # The last four digits of a Social Security number: the one a question carried, or the one a
  # payer returned. The rest of the number is never kept. Only a comparison leaves this object:
  # no reader returns the digits, and it prints none of them, with EdiGem.reveal on or off, so a
  # revealed Person or Person::Asked holding one prints none either.
  #
  # Payers fill the SSN inconsistently, some masked (XXX-XX-1234). Hyphens and spaces are
  # dropped; the four characters left at the end must all be digits to be compared.
  class LastFour
    SEPARATORS = "- "
    DIGITS = /\A\d{4}\z/
    PRINTED = "#<EdiGem::LastFour>"

    # nil when nothing was given (nil or blank); otherwise the last four, readable or not.
    def self.of(ssn)
      return ssn if ssn.is_a?(self)

      new(ssn) unless ssn.to_s.strip.empty?
    end

    def initialize(ssn)
      last = ssn.to_s.delete(SEPARATORS)[-4..]
      @digits = last if last.to_s.match?(DIGITS)
      freeze
    end

    # Whether four digits could be read.
    def readable? = !@digits.nil?

    # This one (the question's) against `other` (the payer's, or nil): :matched or :differs;
    # :not_compared when this one has no four digits, so there is nothing of ours to compare; and
    # :not_returned when ours is readable and the payer's is nil or has no four digits.
    def compare(other)
      return :not_compared unless readable?
      return :not_returned unless other&.readable?

      other.same_digits?(@digits) ? :matched : :differs
    end

    # Two hold the same last four, or neither holds four readable digits. There is no #hash made
    # from the digits, since it would give them away.
    def ==(other) = other.instance_of?(self.class) && other.same_digits?(@digits)

    def inspect = PRINTED
    def to_s = PRINTED

    def pretty_print(printer)
      printer.text(PRINTED)
    end

    protected

    def same_digits?(digits) = @digits == digits
  end
end
