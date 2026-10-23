# frozen_string_literal: true

module EdiGem
  class Person
    # Who a check or discovery asks about, as the caller holds them: a first name, last name and
    # date of birth (a Date), the core every comparison reads. Not a Person, which is someone as
    # the payer holds them. Prints none of its values, so it is safe in a log line or an error.
    #
    # A discovery may also have been given an address (an Address) and an SSN, details beside the
    # core: they are compared apart (#given_fields) and never change how the core compares. Of
    # the SSN only the last four are kept (LastFour), and nothing reads them back.
    class Asked
      include Concealed

      FIELDS = %i[first_name last_name date_of_birth].freeze

      attr_reader(*FIELDS, :address)

      def initialize(first_name:, last_name:, date_of_birth:, address: nil, ssn: nil)
        @first_name = first_name
        @last_name = last_name
        @date_of_birth = date_of_birth
        @address = address
        @ssn_last_four = LastFour.of(ssn)
        freeze
      end

      # The core only: what a comparison of the person reads.
      def to_h = FIELDS.to_h { |field| [field, public_send(field)] }

      # This person with the given fields changed, keeping the details given beside the core.
      def with(**changes) = self.class.new(**to_h, address: @address, ssn: @ssn_last_four, **changes)

      # The core and the given details alike. One asked with neither equals one asked before
      # either could be given.
      def ==(other)
        other.instance_of?(self.class) && other.to_h == to_h && other.given == given
      end
      alias eql? ==

      def hash = [self.class, to_h].hash

      # A person missing a name or birth date can't be asked about.
      def complete?
        to_h.values.none? { |value| EdiGem.blank?(value) }
      end

      # The names as they are sent to a payer, so any spelling sent the same way is the same person.
      def plain
        with(first_name: Identity.plain(@first_name), last_name: Identity.plain(@last_name))
      end

      # As the payer is sent them, on `member_id`. `relationship` is nil for a dependent whose
      # relationship is not known.
      def subscriber(member_id:, relationship: :self)
        Subscriber.new(member_id: member_id, first_name: @first_name, last_name: @last_name,
                       date_of_birth: Codec.yyyymmdd(@date_of_birth), relationship: relationship)
      end

      # How each detail given beside the core compares with `person`, the one the payer holds
      # (nil when the answer named nobody): `address` and `ssn_last_four`, each :matched,
      # :differs, :not_compared (ours can't be compared) or :not_returned (the payer's can't), as
      # Address#compare and LastFour#compare say, and only those this person carries.
      def given_fields(person)
        { address: @address&.compare(person&.address),
          ssn_last_four: @ssn_last_four&.compare(person&.ssn_last_four) }.compact
      end

      def to_s = inspect

      protected

      def given = [@address&.to_h, @ssn_last_four]
    end
  end
end
