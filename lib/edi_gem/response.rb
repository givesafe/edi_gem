# frozen_string_literal: true

module EdiGem
  # What came back: benefits and rejections in the shared vocabulary, the raw payload, and the
  # exchanges that carried it.
  class Response
    include Concealed

    # One state per distinct next step:
    #   complete        coverage answered in full
    #   partial         benefit lines plus a rejection for part of the question
    #   no_coverage     answered, and no coverage found
    #   not_identified  the payer could not match the subscriber; correct the identifiers
    #   payer_silent    the payer did not answer; ask again later
    #   rejected        the request or the provider was refused; fix before asking again
    #   pending         an asynchronous answer that has not arrived; resolve the handle
    # An unknown answer is never reported as no coverage.
    STATES = %i[complete partial no_coverage not_identified payer_silent rejected pending].freeze

    # The states in which the payer answered for our provider: benefits, a settled no coverage, or a person it
    # looked up and could not match.
    PROVIDER_ACCEPTED = %i[complete partial no_coverage not_identified].freeze

    TEST_MODE = "test"

    attr_reader :benefits, :rejections, :payload, :exchanges, :handle, :details, :stored,
                :archive_failure, :people, :found_plans

    # One field for each part of an answer, so it runs one line past the length rule.
    def initialize(benefits: [], rejections: [], payload: nil, exchanges: [], handle: nil, # rubocop:disable Metrics/MethodLength
                   state: nil, details: {}, settled: false, stored: nil, archive_failure: nil,
                   people: [], found_plans: [], directory: nil)
      @benefits = benefits
      @rejections = rejections
      @people = people
      @found_plans = found_plans
      @payload = payload
      @exchanges = exchanges
      @handle = handle
      @state = state
      @details = details
      @settled = settled
      @stored = stored
      @archive_failure = archive_failure
      @directory = directory
    end

    # `stored` is the Archive::Stored for the raw bodies when the send asked to archive. nil
    # means archiving was not asked for, or the write failed: then `archive_failure` is the
    # ArchiveFailed, and the answer is still whole, only unfiled.
    def archived? = !@stored.nil?

    # The vendor's label for the mode it served this in ("test" or "production"), or nil. Not
    # proof of whether a real payer was reached; Stedi labels every discovery "production".
    def application_mode
      @details[:application_mode]
    end

    def test_mode?
      application_mode == TEST_MODE
    end

    # The identifier to quote to the vendor or payer about this exchange.
    def trace_id
      @details[:trace_id]
    end

    # Stedi's warning codes on the answer, for the caller to log; none decides the answer.
    def warning_codes
      @details.fetch(:warning_codes, [])
    end

    def state
      @state ||= read_state.name
    end

    # The policyholder the answer names, or nil. `people` are an eligibility answer's; a
    # discovery's are each on their own FoundPlan.
    def subscriber_person
      @people.find { |person| !person.dependent? }
    end

    def dependent_people
      @people.select(&:dependent?)
    end

    # The refusal that decided the state (State#deciding_rejection), not the first one listed: a
    # payer can list a refusal that decides nothing ahead of the one that does. nil with none.
    def deciding_rejection = read_state.deciding_rejection

    # The deciding refusal in codes alone (Rejection#summary), to record beside an answer that isn't
    # one; nil when none.
    def error_summary = deciding_rejection&.summary

    # The payer refused the request as sent: a 42 whose follow-up is C, N or S, which Stedi says is
    # a problem with the request, for Stedi support (Rejection#resubmission_refused?).
    def resubmission_refused? = payer_rejections.any?(&:resubmission_refused?)

    # The payer refused our setup, not the person: a 41 (our NPI, tax ID or portal credentials) or a
    # T4 (the payer name or ID we sent) in the payer lane, or a T4 in the provider's, as Stedi reads
    # them (Rejection#our_setup_refused?). The state stays payer_silent; the caller files it as ours.
    def our_setup_refused? = payer_rejections.any?(&:our_setup_refused?)

    # Whether Stedi says to ask the payer again at once: any of its refusals is Rejection#retryable?,
    # so a 42 beside a 79 is asked again and a 79 alone is not.
    def ask_again? = payer_rejections.any?(&:retryable?)

    def rejections_at(level)
      @rejections.select { |rejection| rejection.level == level }
    end

    # The refusals that are the payer's to read (Rejection#about_payer?): its lane, and in another
    # lane a reason Stedi reads as the payer's there.
    def payer_rejections
      @rejections.select(&:about_payer?)
    end

    def provider_refusals
      @rejections.select(&:about_provider?)
    end

    # What the answer says of our provider's standing with the payer: :needs_provider_details when every
    # refusal about our provider asks for our tax ID and address (Rejection#provider_details_wanted?),
    # :refused when any other refusal is about our provider, :not_connected when Stedi couldn't connect to
    # the payer and says not to ask again on its own (#not_connected?), :accepted when the payer answered
    # for it (PROVIDER_ACCEPTED), a person it could not match included, and nil when it did neither (it was silent,
    # has not answered yet, or refused the request for another reason).
    def provider_standing
      return provider_refused_standing if provider_refusals.any?
      return :not_connected if not_connected?

      :accepted if PROVIDER_ACCEPTED.include?(state)
    end

    # Stedi had a problem connecting to the payer (AAA 79) and nothing beside it says to ask again: Stedi,
    # "Don't automatically retry… contact Stedi support". A 79 beside a 42 or 80 is asked again (#ask_again?).
    def not_connected?
      !ask_again? && payer_rejections.any? { |rejection| rejection.code == Rejection::CONNECTION_PROBLEM }
    end

    def active_benefits
      @benefits.select(&:active?)
    end

    # Whether the plan covers the person on this day (Coverage's two-part test).
    def coverage_on(date) = Coverage.on(@benefits, date)

    # A discovery's medical plans (MedicalPlan.all): dental and vision left out, and a Medicaid
    # plan an MCO names paired with the MCO's. `directory` is the source's payer directory, which
    # each plan asks for its payer_id; nil on an answer no source read.
    def medical_plans = MedicalPlan.all(@found_plans, directory: @directory)

    # A check's answer as the plan it is about (CheckedPlan). `identification` is who the caller
    # reads the answer to be about: anything answering answered_as and match.
    def checked_plan(identification:) = CheckedPlan.new(self, identification: identification)

    private

    def provider_refused_standing
      provider_refusals.all?(&:provider_details_wanted?) ? :needs_provider_details : :refused
    end

    def read_state
      @read_state ||= State.new(benefits: @benefits, rejections: @rejections, handle: @handle, settled: @settled)
    end

    def concealed_inspect
      "#<#{self.class} #{state} benefits=#{@benefits.size} rejections=#{@rejections.size} " \
        "details=#{@details.keys.join(",")}>"
    end
  end
end
