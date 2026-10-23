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

    TEST_MODE = "test"

    attr_reader :benefits, :rejections, :payload, :exchanges, :handle, :details, :stored,
                :people, :found_plans

    # One field for each part of an answer, so it runs one line past the length rule.
    def initialize(benefits: [], rejections: [], payload: nil, exchanges: [], handle: nil, # rubocop:disable Metrics/MethodLength
                   state: nil, details: {}, settled: false, stored: nil, people: [], found_plans: [],
                   directory: nil)
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
      @directory = directory
    end

    # `stored` is the Archive::Stored for the raw bodies when the send asked to archive. nil
    # means archiving was not asked for; a failed archive raises instead.
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

    def state
      @state ||= State.new(benefits: @benefits, rejections: @rejections, handle: @handle, settled: @settled).name
    end

    # The policyholder the answer names, or nil. `people` are an eligibility answer's; a
    # discovery's are each on their own FoundPlan.
    def subscriber_person
      @people.find { |person| !person.dependent? }
    end

    def dependent_people
      @people.select(&:dependent?)
    end

    # Who of the people on the answer is the one asked about. `asked` is a hash of first_name,
    # last_name and date_of_birth; `as_dependent` whether they were sent as a dependent.
    #
    # An answer can name the subscriber and their dependents together, and a payer may move the
    # patient between the two (X12 RFI 975), or ignore a dependent and answer about the
    # subscriber. So the part asked about is compared first, then the other; the first person who
    # matches is the one. When nobody matches, the part asked about is the one reported: a
    # dependent asked about and no dependent back means the payer answered about the subscriber.
    def identify(asked, as_dependent: false, **options)
      found = compared(asked.to_h, as_dependent, options)
      Identification.new(**found.to_h, refusal: PersonRefusal.among(@rejections), member_id_asked: true)
    end

    # What the answer says of the person's coverage on the day asked about (a Verdict name). A
    # check names no date of service, so the payer answers about the day it was asked. An answer
    # about someone else (`identification` mismatched) is unanswered, never their coverage; with
    # no identification, only the payer's refusal can say so.
    def verdict(on:, identification: nobody_compared)
      coverage = coverage_about(on, identification)
      coverage ? reading.of_plan(coverage) : :unanswered
    end

    # The status code of the benefit line that decided #verdict (Coverage::Finding#code), to record
    # beside it; nil when no line decided it: an unanswered state, or an answer about someone else.
    def verdict_code(on:, identification:)
      coverage = coverage_about(on, identification)
      reading.code_of(coverage) if coverage
    end

    # A discovery's verdict among its medical plans, each read on the day: a plan that came back
    # decides, whatever refusals came with it.
    def discovery_verdict(on:, plans: medical_plans) = reading.among(plans.map { |plan| plan.coverage_on(on) })

    # The code of the first refusal, to record beside an unanswered verdict; nil when none. A
    # code the codec did not name is its raw string.
    def error_code = @rejections.first&.code&.to_s

    def rejections_at(level)
      @rejections.select { |rejection| rejection.level == level }
    end

    def provider_refusals
      @rejections.select(&:about_provider?)
    end

    def active_benefits
      @benefits.select(&:active?)
    end

    # Whether the plan covers the person on this day (Coverage's two-part test).
    def coverage_on(date) = Coverage.on(@benefits, date)

    # A discovery's medical plans (MedicalPlan.all): dental and vision left out, and a Medicaid
    # plan an MCO names paired with the MCO's. `asked` is who the discovery asked about, for each
    # plan's identification. `directory` is the source's payer directory, which each plan asks for
    # its payer_id; nil on an answer no source read.
    def medical_plans(asked: nil) = MedicalPlan.all(@found_plans, directory: @directory, asked: asked)

    # A check's answer as the plan it is about (CheckedPlan), for the person `identification`
    # names (see #verdict).
    def checked_plan(identification: nobody_compared) = CheckedPlan.new(self, identification: identification)

    private

    # Who the answer is about when nobody was asked: only the payer's refusal can say anything.
    def nobody_compared = identify({})

    # The plan's coverage on the day, or nil when the answer is about someone else.
    def coverage_about(on, identification) = (coverage_on(on) unless identification.mismatched?)

    # The Verdict for this answer's state and refusals.
    def reading = Verdict.new(state, provider_refused: provider_refusals.any?)

    # The first person who matches, in the order `identify` describes.
    def compared(asked, as_dependent, options)
      order = [subscriber_person, *dependent_people].compact
      found = (as_dependent ? order.rotate : order).map { |person| Identification.of(person, asked, **options) }
      found.find { |one| one.result.matched? } || found.first || Identification.of(nil, asked)
    end

    def concealed_inspect
      "#<#{self.class} #{state} benefits=#{@benefits.size} rejections=#{@rejections.size} " \
        "details=#{@details.keys.join(",")}>"
    end
  end
end
