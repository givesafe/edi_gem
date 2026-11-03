# frozen_string_literal: true

module EdiGem
  class Person
    # Who a check or discovery asks about, as the caller holds them: a first name, last name and
    # date of birth (a Date). Not a Person, which is someone as the payer holds them. Prints none
    # of its values, so it is safe in a log line or an error.
    class Asked
      include Concealed

      FIELDS = %i[first_name last_name date_of_birth].freeze

      attr_reader(*FIELDS)

      def initialize(first_name:, last_name:, date_of_birth:)
        @first_name = first_name
        @last_name = last_name
        @date_of_birth = date_of_birth
        freeze
      end

      def to_h = FIELDS.to_h { |field| [field, public_send(field)] }

      # This person with the given fields changed. A field changed to nil is not sent.
      def with(**changes) = self.class.new(**to_h, **changes)

      # Whether either name holds an accented letter written another way too (Identity.another_spelling).
      def another_spelling?
        names.any? { |name| Identity.another_spelling(name) != Identity.payer_normalized(name) }
      end

      # This person with both names spelled the other way (Identity.another_spelling): Müller as MUELLER.
      def another_spelling
        first_name, last_name = names.map { |name| Identity.another_spelling(name) }
        with(first_name: first_name, last_name: last_name)
      end

      # Whether either name holds an apostrophe or hyphen, which a payer may hold without.
      def punctuated?
        names.any? { |name| Identity.unpunctuated(name) != Identity.payer_normalized(name) }
      end

      # This person with both names as a payer holding them without punctuation would
      # (Identity.unpunctuated): O'Brien-Smith as OBRIEN SMITH.
      def unpunctuated
        first_name, last_name = names.map { |name| Identity.unpunctuated(name) }
        with(first_name: first_name, last_name: last_name)
      end

      def ==(other) = other.instance_of?(self.class) && other.to_h == to_h
      alias eql? ==

      def hash = [self.class, to_h].hash

      # A person missing a name or birth date can't be asked about.
      def complete?
        to_h.values.none? { |value| EdiGem.blank?(value) }
      end

      # As the payer is sent them, on `member_id`. `relationship` is nil for a dependent whose
      # relationship is not known.
      def subscriber(member_id:, relationship: :self)
        Subscriber.new(member_id: member_id, first_name: @first_name, last_name: @last_name,
                       date_of_birth: Codec.yyyymmdd(@date_of_birth), relationship: relationship)
      end

      def to_s = inspect

      private

      def names = [@first_name, @last_name]
    end
  end
end
