# frozen_string_literal: true

module EdiGem
  # What a payer said about one person's plan, in the clearinghouse's coverage terms. A check's
  # answer (CheckedPlan) and each medical plan a discovery found (MedicalPlan) both play this
  # role, so a caller reads either the same way and never reads a benefit line's codes itself:
  #
  #   payer_code       the payer's code as the answer gives it, or nil
  #   member_id        the subscriber's insurance ID (a dependent is on the subscriber's), or nil
  #   prior_member_id  the ID member_id replaced, when the payer names it (X12 REF Q4, "Prior
  #                    Identifier Number"; Stedi's planInformation.priorIdNumber), or nil. It may
  #                    equal member_id: the payer's own words, read as sent
  #   medicaid_id      the state Medicaid ID tied to the plan, or nil
  #   plan_name        the payer's name for the plan, or nil (each host says which line names it)
  #   plan_number      the payer's number for the plan, or nil
  #   group_number     the employer or group number, or nil when the answer holds none
  #   status_on(date)  what the plan's own lines say of that day (Coverage's two-part test):
  #                    :active, :inactive, or :unknown when they say neither. Not knowing is not
  #                    a denial. It does not weigh who the payer answered about; the caller does
  #   relationship     :self or :dependent, as the payer said; nil when it did not say, nobody
  #                    was compared, or the payer refused the person
  #   lines            the benefit lines worth keeping, as Lines; none when the payer sent none
  #   plan_begins_on   the plan's own begin and end dates, as Dates: planDateInformation's `plan`
  #   plan_ends_on     (a day or a range) when sent, else its planBegin and planEnd. nil when the
  #                    answer holds none, or a value that is not a YYYYMMDD string naming a real
  #                    day. Never a line's dates, nor the eligibility period Coverage weighs.
  #                    An end in the year 9999 is nil too: payers send it as a placeholder until
  #                    the plan ends, so it is no end date
  #
  # The status code behind status_on is coverage_on(date).code, from the one Finding that decides
  # the status: nil when the plan's dates or an implied term decided.
  #
  # A host provides `benefits`, `[]` (a field of the plan as a whole) and `coverage_on(date)` (a
  # Coverage::Finding); the role gives it `lines`, `status_on`, the plan's dates and the fields
  # above read through `[]`, which a host overrides where it reads one elsewhere. A MedicalPlan
  # also answers payer_id, which asks the source's payer directory over the network (see
  # MedicalPlan#payer_id).
  module AnsweredPlan
    # The statuses on a day a caller acts on; anything else is :unknown.
    STATUSES = %i[active inactive].freeze

    # One benefit line as a caller keeps it. `benefit_type` is what the line says: a plan term
    # (:co_payment, :deductible, ...) or, on a status line, the status (:active, :inactive,
    # :non_covered, :cannot_process). `plan_name` is the plan the line belongs to, when one answer
    # covers more than one plan. `in_network` is nil when the payer did not say.
    Line = Struct.new(:benefit_type, :service_types, :insurance_type, :plan_name, :in_network,
                      keyword_init: true) do
      # Only benefit lines, not the plan around them.
      def self.all(benefits)
        benefits.select(&:line?).map do |line|
          new(benefit_type: line.benefit_type || line.status, service_types: Array(line.service_types),
              insurance_type: line.insurance_type, plan_name: line.plan_name, in_network: line.in_network)
        end
      end
    end

    def lines = Line.all(benefits)

    def status_on(date)
      status = coverage_on(date).status
      STATUSES.include?(status) ? status : :unknown
    end

    # The year many payers put in a plan's end date until the plan ends (9999-12-31), as Stedi's
    # Medicaid guide says; it tells nothing of when the plan ends.
    PLACEHOLDER_YEAR = 9999

    def plan_begins_on = Codec.day(self[:plan_begins_on])

    def plan_ends_on
      day = Codec.day(self[:plan_ends_on])
      day unless day&.year == PLACEHOLDER_YEAR
    end

    # The plan's fields as the plan as a whole holds them (`[]`). A host overrides the ones it
    # reads elsewhere: a check's plan is named by its first active line, and a discovery's
    # Medicaid ID may come from the Medicaid plan beside it.
    def payer_code = self[:payer_code]
    def member_id = self[:member_id]
    def prior_member_id = self[:prior_member_id]
    def medicaid_id = self[:state_insurance_id]
    def plan_name = self[:plan_name]
    def plan_number = self[:plan_number]
    def group_number = self[:group_number]
  end
end
