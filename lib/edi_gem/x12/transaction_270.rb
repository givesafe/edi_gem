# frozen_string_literal: true

module EdiGem
  module X12
    # A 270 eligibility inquiry (005010X279A1) written from an Inquiry: the transaction set,
    # ST through SE. The envelope around it is Interchange's.
    #
    # Payer-specific identifier choices are expressed by what the caller puts on the Provider,
    # not by branches here.
    class Transaction270
      include People

      VERSION = "005010X279A1"
      HIERARCHY = "0022"
      INQUIRY = "13"

      # HL03 level codes: the payer, the provider, the subscriber and the dependent. The
      # dependent level is written only when the inquiry has a dependent.
      SOURCE_LEVEL = "20"
      RECEIVER_LEVEL = "21"
      SUBSCRIBER_LEVEL = "22"
      DEPENDENT_LEVEL = "23"

      HAS_CHILDREN = "1"
      NO_CHILDREN = "0"

      # NM101 entity identifiers, and NM102: 1 is a person, 2 an organisation.
      PAYER = "PR"
      PROVIDER = "1P"
      SUBSCRIBER = "IL"
      DEPENDENT = "03"
      PERSON = "1"

      # INS01 N: the dependent is not the insured.
      NOT_INSURED = "N"
      ORGANISATION = "2"

      # NM108 identifier qualifiers. PI is a payer identification number, XX an NPI, MI a
      # member identification number.
      PAYER_ID = "PI"
      NPI = "XX"
      MEMBER_ID = "MI"

      # DTP01 291 is the plan date. D8 is one date, RD8 a range written YYYYMMDD-YYYYMMDD.
      PLAN_DATE = "291"
      SINGLE_DATE = "D8"
      DATE_RANGE = "RD8"
      RANGE = /\A\d{8}-\d{8}\z/

      # TRN01 1: the trace number is assigned by the sender.
      TRACE_ASSIGNED_HERE = "1"

      # `trace` comes back on the 271 and pairs the answer with its question. `submitter_id`
      # is echoed in BHT03 and defaults to the trace.
      def initialize(inquiry, payer_code:, trace:, payer_name: "", submitter_id: nil,
                     originator: nil, control_number: "0001", now: nil)
        @inquiry = inquiry
        @payer_code = payer_code
        @payer_name = payer_name
        @trace = trace
        @submitter_id = submitter_id || trace
        @originator = originator
        @control_number = control_number
        @now = now || Time.now
      end

      def segments
        [*header, *source, *receiver, *subscriber, *dependent].then { |body| body + [trailer(body)] }
      end

      def to_s
        segments.join
      end

      private

      def header
        [segment("ST", "270", @control_number, VERSION),
         segment("BHT", HIERARCHY, INQUIRY, @submitter_id, date, time)]
      end

      # 2000A/2100A: the payer. NM103 is informational; NM109 routes.
      def source
        [segment("HL", "1", "", SOURCE_LEVEL, HAS_CHILDREN),
         segment("NM1", PAYER, ORGANISATION, @payer_name, "", "", "", "", PAYER_ID, @payer_code)]
      end

      # 2000B/2100B: the provider, with the tax id in REF when one is given.
      def receiver
        provider = @inquiry.provider
        [segment("HL", "2", "1", RECEIVER_LEVEL, HAS_CHILDREN),
         segment("NM1", PROVIDER, *provider_name(provider), "", "", NPI, provider.npi),
         *optional("REF", "TJ", provider.tax_id)]
      end

      # Omitted when the inquiry names no date, which asks about today.
      def plan_date
        on = @inquiry.service_date
        return [] if on.nil?

        [segment("DTP", PLAN_DATE, on.match?(RANGE) ? DATE_RANGE : SINGLE_DATE, on)]
      end

      # SE01 counts every segment from ST to SE inclusive, so it is one more than the body.
      def trailer(body)
        segment("SE", (body.length + 1).to_s, @control_number)
      end

      def provider_name(provider)
        return [ORGANISATION, provider.organization_name.to_s, "", ""] if provider.organization_name

        [PERSON, provider.last_name.to_s, provider.first_name.to_s, ""]
      end

      # TRN03 identifies who assigned the trace, conventionally 1 plus a nine-digit EIN. Falls
      # back to the trace.
      def originator
        @originator || @trace
      end

      def date = @now.strftime("%Y%m%d")

      def time = @now.strftime("%H%M")

      def optional(id, *elements)
        elements.last.to_s.empty? ? [] : [segment(id, *elements)]
      end

      # Trailing empty elements are dropped.
      def segment(id, *elements)
        written = elements.map(&:to_s)
        written.pop while written.any? && written.last.empty?
        "#{[id, *written].join("*")}~"
      end
    end
  end
end
