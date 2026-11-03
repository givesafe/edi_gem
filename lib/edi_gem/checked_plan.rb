# frozen_string_literal: true

module EdiGem
  # The plan an eligibility check's answer is about, read as an AnsweredPlan. A check asks about
  # one plan, so the whole answer is that plan. `identification` is the caller's reading of who the
  # answer is about (anything answering answered_as and match), and decides the relationship.
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
    # It does not weigh who the payer answered about; that is the caller's.
    def coverage_on(date) = @response.coverage_on(date)

    # As the payer answered: :self about the subscriber, :dependent about a dependent. nil when
    # nobody was compared or the payer refused the person.
    def relationship = RELATIONSHIPS[@identification.answered_as]

    def concealed_inspect
      "#<#{self.class} #{@response.inspect} match=#{@identification.match}>"
    end

    private

    def naming_benefit
      @response.active_benefits.first || benefits.first
    end
  end
end
