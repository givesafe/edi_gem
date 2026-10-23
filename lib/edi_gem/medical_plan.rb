# frozen_string_literal: true

module EdiGem
  # One medical coverage a discovery found: a FoundPlan, together with the state Medicaid plan it
  # names as its primary payer when the answer holds that one too (an MCO's plan and the Medicaid
  # plan it manages are one coverage). Dental and vision plans are not medical plans.
  #
  # Its own fields are the FoundPlan's; the Medicaid plan adds its ID and its benefit lines. It
  # plays AnsweredPlan.
  #
  # `directory` is the source's payer directory (anything answering payer_id_for and
  # directory_name), asked only when payer_id is, so reading an answer again makes no directory
  # call unless a caller wants the payer's ID. `asked` is who the discovery asked about, a
  # Person::Asked.
  class MedicalPlan
    include Concealed
    include AnsweredPlan

    # The medical plans among a discovery's found plans. A Medicaid plan another plan names as its
    # primary payer goes with that plan, and is not a plan of its own.
    def self.all(found_plans, directory: nil, asked: nil)
      medicaid_plans = found_plans.select { |plan| named_as_primary?(plan, found_plans) }
      (found_plans - medicaid_plans).select(&:medical?).map do |plan|
        new(plan, medicaid: medicaid_for(plan, medicaid_plans), directory: directory, asked: asked)
      end
    end

    # Whether another of the found plans names `plan` as its primary payer.
    def self.named_as_primary?(plan, found_plans)
      (found_plans - [plan]).any? { |other| other.names_as_primary_payer?(plan) }
    end

    # The Medicaid plan `plan` names as its primary payer, if one is found.
    def self.medicaid_for(plan, medicaid_plans)
      medicaid_plans.find { |medicaid| plan.names_as_primary_payer?(medicaid) }
    end
    private_class_method :named_as_primary?, :medicaid_for

    def initialize(found_plan, medicaid: nil, directory: nil, asked: nil)
      @found_plan = found_plan
      @medicaid_plan = medicaid
      @directory = directory
      @asked = asked
    end

    # The clearinghouse's payer ID for the plan's payer. Network I/O: the first time a source is
    # asked about a payer code, it searches its payer directory (a request, not billed), and it
    # remembers the answer for its lifetime, so plans with one payer code ask once between them.
    # nil means the directory holds no single payer that answers to the code, or that the plan
    # came with no directory (an answer no source read). A failed search raises as the source's
    # every request does (Fault, a RequestFailed; UnreadableBody for an answer that is not JSON),
    # and nothing is remembered, so asking again searches again.
    def payer_id = @directory&.payer_id_for(payer_code)

    # The clearinghouse whose payer IDs payer_id is one of (:stedi), or nil with no directory.
    def clearinghouse = @directory&.directory_name

    # A field of the plan itself (plan_name, plan_number, ...), as FoundPlan#[] reads it: the
    # first of its own lines that holds it. The Medicaid plan's lines name none of the plan's own.
    def [](field) = @found_plan[field]

    # The state Medicaid ID: the one on the plan's own lines wins over the Medicaid plan's member ID.
    def medicaid_id = super || @medicaid_plan&.member_id

    # The plan's lines, then the Medicaid plan's.
    def benefits
      @found_plan.benefits + Array(@medicaid_plan&.benefits)
    end

    # Who the payer matched, as it holds them (FoundPlan#person), or nil.
    def person = @found_plan.person

    # The address the payer holds for the person matched, or nil.
    def address = person&.address

    # :self, :dependent, or nil when the payer did not say (Person#relationship).
    def relationship = person&.relationship

    # How the person matched compares with who was asked about (FoundPlan#identify).
    def identify(asked, **options) = @found_plan.identify(asked, **options)

    # The person matched compared with `asked`, and the details given beside the core with the
    # ones the payer holds; with nobody asked, nothing is compared and nothing was given.
    def identification
      @identification ||= identify(@asked.to_h, given_fields: given_fields)
    end

    # Coverage's finding for the plan's own lines on this day.
    def coverage_on(date) = @found_plan.coverage_on(date)

    def concealed_inspect
      "#<#{self.class} #{@found_plan.inspect} medicaid=#{!@medicaid_plan.nil?}>"
    end

    private

    def given_fields = @asked&.given_fields(person) || {}
  end
end
