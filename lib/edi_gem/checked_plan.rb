# frozen_string_literal: true

module EdiGem
  # The plan an eligibility check's answer is about, read as an AnsweredPlan. A check asks about
  # one plan, so the whole answer is that plan. `identification` is the Response's for the person
  # asked about (Response#identify), and decides the relationship.
  class CheckedPlan
    include Concealed
    include PlanFields
    include AnsweredPlan

    # The part of the answer the person came back in, as the relationship it means.
    RELATIONSHIPS = { subscriber: :self, dependent: :dependent }.freeze

    attr_reader :identification

    def initialize(response, identification:)
      @response = response
      @identification = identification
    end

    def benefits = @response.benefits

    # The plan is named by its first active line. A plan active by an implied term has no active
    # line, so its first benefit names it. nil when that one names none.
    def plan_name = naming_benefit&.plan_name
    def plan_number = naming_benefit&.plan_number

    # Whether the plan covers the person on this day (Coverage's two-part test); status_on reads it.
    # A check's verdict, which weighs who the payer answered about, is #verdict.
    def coverage_on(date) = @response.coverage_on(date)

    # What the answer says of the person's coverage on the day asked about (a Verdict name). A
    # check names no date of service, so the payer answers about the day it was asked. An answer
    # about someone else (`identification` mismatched) is unanswered, never their coverage; with
    # nobody compared, only the payer's refusal can say so.
    def verdict(on:)
      coverage = coverage_about(on)
      coverage ? @response.reading.of_plan(coverage) : :unanswered
    end

    # What the answer established about the person asked about, on the day (a Finding): the
    # meaning #verdict folds into one word to record.
    def finding(on:) = Finding.of_check(@response, @identification, on: on)

    # The status code of the benefit line that decided #verdict (Coverage::Finding#code), to record
    # beside it; nil when no line decided it: an unanswered state, or an answer about someone else.
    def verdict_code(on:)
      coverage = coverage_about(on)
      @response.reading.code_of(coverage) if coverage
    end

    # As the payer answered: :self about the subscriber, :dependent about a dependent. nil when
    # nobody was compared or the payer refused the person.
    def relationship = RELATIONSHIPS[@identification.answered_as]

    def concealed_inspect
      "#<#{self.class} #{@response.inspect} match=#{@identification.match}>"
    end

    private

    # The plan's coverage on the day, or nil when the answer is about someone else.
    def coverage_about(on) = (coverage_on(on) unless @identification.mismatched?)

    def naming_benefit
      @response.active_benefits.first || benefits.first
    end
  end
end
