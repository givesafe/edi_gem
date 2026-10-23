# frozen_string_literal: true

module EdiGem
  # What an answer says of the person's coverage, in one word to record:
  #   active            the plan covers the person on the day asked about
  #   inactive          the plan does not cover them that day
  #   not_covered       the payer answered and found no coverage
  #   unanswered        the payer did not say, or answered about someone else
  #   provider_refused  the payer refused our provider; fix that before asking again
  #   pending           an asynchronous answer that has not arrived
  # An error is never a lapse: whatever the payer did not say reads as unanswered.
  class Verdict
    NAMES = %i[active inactive not_covered unanswered provider_refused pending].freeze

    ANSWERED = %i[complete partial].freeze

    # What the payer said of the plan (service type 30); cannot_process or nothing is unanswered.
    BY_COVERAGE = { active: :active, inactive: :inactive, non_covered: :not_covered }.freeze

    # What the state says when no plan's coverage decides. An answer with no plan in it found none.
    BY_STATE = { complete: :not_covered, partial: :not_covered, no_coverage: :not_covered,
                 not_identified: :not_covered, payer_silent: :unanswered, pending: :pending }.freeze

    # `state` is the Response's; `provider_refused` whether any refusal was about our provider.
    def initialize(state, provider_refused:)
      @state = state
      @provider_refused = provider_refused
    end

    # Whether a check's plan coverage decides it (#of_plan): only an answered state's does.
    def decided_by_plan? = ANSWERED.include?(@state)

    # The code of the plan's line (a Coverage::Finding's) when that line decides the check; nil
    # when the state does.
    def code_of(coverage) = (coverage.code if decided_by_plan?)

    # A check's: the plan's coverage (a Coverage::Finding) decides an answered check.
    def of_plan(coverage)
      return of_state unless decided_by_plan?

      BY_COVERAGE.fetch(coverage.status, :unanswered)
    end

    # A discovery's: the best any plan found says, where a plan neither active nor inactive is no
    # denial. With no plan, the state decides.
    def among(coverages)
      return of_state if coverages.empty?
      return :active if coverages.any?(&:active?)

      coverages.any? { |coverage| coverage.status == :inactive } ? :inactive : :unanswered
    end

    private

    def of_state
      return BY_STATE.fetch(@state) unless @state == :rejected

      @provider_refused ? :provider_refused : :unanswered
    end
  end
end
