# frozen_string_literal: true

module EdiGem
  module X12
    # The ISA/GS envelope around one or more transaction sets, carrying the identifiers a
    # clearinghouse assigns at enrolment.
    #
    # The ISA is fixed-width: every element is padded to its declared length, because readers
    # take the delimiters from it by byte offset. A short ISA parses as no segments at all.
    class Interchange
      SEGMENT = "~"
      ELEMENT = "*"
      COMPONENT = ":"
      REPETITION = "^"

      VERSION = "00501"
      GROUP_VERSION = "005010X279A1"
      # GS01 HS is an eligibility inquiry; the 271 comes back as HB.
      INQUIRY_GROUP = "HS"

      # ISA element widths, in order, from the 005010 interchange control header. ISA13 is the
      # interchange control number and IEA02 has to repeat it exactly.
      WIDTHS = { authorization_qualifier: 2, authorization: 10, security_qualifier: 2,
                 security: 10, sender_qualifier: 2, sender: 15, receiver_qualifier: 2,
                 receiver: 15, date: 6, time: 4, repetition: 1, version: 5,
                 control_number: 9, acknowledgement: 1, usage: 1, component: 1 }.freeze

      # ISA05/ISA07 qualifier. ZZ is "mutually defined", as a clearinghouse-assigned id is.
      MUTUALLY_DEFINED = "ZZ"

      # ISA14. 0 requests no TA1 interchange acknowledgement.
      NO_ACKNOWLEDGEMENT = "0"

      # ISA15 usage indicator: T is test, P is production (billed).
      TEST = "T"
      PRODUCTION = "P"

      def initialize(sender:, receiver:, control_number:, application_sender: nil,
                     application_receiver: nil, group_control_number: nil,
                     sender_qualifier: MUTUALLY_DEFINED, receiver_qualifier: MUTUALLY_DEFINED,
                     usage: TEST, now: nil)
        @sender = sender
        @receiver = receiver
        @sender_qualifier = sender_qualifier
        @receiver_qualifier = receiver_qualifier
        @control_number = control_number
        @application_sender = application_sender || sender
        @application_receiver = application_receiver || receiver
        @group_control_number = group_control_number || control_number
        @usage = usage
        @now = now || Time.now
      end

      # `transactions` is one or more transaction sets, each a list of segments.
      def wrap(*transactions)
        [isa, group_header, *transactions.flatten, group_trailer(transactions.length),
         interchange_trailer].join
      end

      def production?
        @usage == PRODUCTION
      end

      private

      # ISA16, the component separator, is the last element.
      def isa
        elements = WIDTHS.map { |field, width| pad(send(field), width) }
        "ISA#{ELEMENT}#{elements.join(ELEMENT)}#{SEGMENT}"
      end

      def group_header
        ["GS", INQUIRY_GROUP, @application_sender, @application_receiver, long_date, time,
         @group_control_number, "X", GROUP_VERSION].join(ELEMENT) + SEGMENT
      end

      def group_trailer(count)
        ["GE", count.to_s, @group_control_number].join(ELEMENT) + SEGMENT
      end

      def interchange_trailer
        ["IEA", "1", pad(control_number, WIDTHS[:control_number])].join(ELEMENT) + SEGMENT
      end

      # Truncates rather than overflows: an overflow would shift every offset after it.
      def pad(value, width)
        value.to_s[0, width].ljust(width)
      end

      # ISA01-04: no authorization or security information; sources authenticate at the
      # transport.
      def authorization_qualifier = "00"

      def authorization = ""

      def security_qualifier = "00"

      def security = ""

      # Read by name so the ISA is written from WIDTHS.
      attr_reader :sender, :receiver, :sender_qualifier, :receiver_qualifier, :usage

      # ISA09 is YYMMDD; GS04 is CCYYMMDD.
      def date = @now.strftime("%y%m%d")

      def long_date = @now.strftime("%Y%m%d")

      def time = @now.strftime("%H%M")

      def repetition = REPETITION

      def version = VERSION

      def control_number = format("%<n>09d", n: @control_number.to_s.gsub(/\D/, "").to_i)

      def acknowledgement = NO_ACKNOWLEDGEMENT

      def component = COMPONENT
    end
  end
end
