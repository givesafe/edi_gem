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

    # The states in which the payer answered for our provider: benefits, or a settled no coverage.
    PROVIDER_ACCEPTED = %i[complete partial no_coverage].freeze

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

    # A discovery's Finding among `plans`, its medical plans (#medical_plans), each read on the
    # day: a plan that came back decides, whatever refusals came with it (Finding.of_discovery).
    def discovery_finding(on:, plans:) = Finding.of_discovery(self, plans, on: on)

    # The code of the first refusal, to record beside an answer that isn't one; nil when none. A
    # code the codec did not name is its raw string.
    def error_code = @rejections.first&.code&.to_s

    def rejections_at(level)
      @rejections.select { |rejection| rejection.level == level }
    end

    def provider_refusals
      @rejections.select(&:about_provider?)
    end

    # What the answer says of our provider's standing with the payer: :refused when any refusal is
    # about our provider, :accepted when the payer answered for it (PROVIDER_ACCEPTED), and nil when
    # it did neither (it was silent, could not match the person, has not answered yet, or refused the
    # request for another reason).
    def provider_standing
      return :refused if provider_refusals.any?

      :accepted if PROVIDER_ACCEPTED.include?(state)
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
    # names; its finding is the check's (CheckedPlan#finding).
    def checked_plan(identification: nobody_compared) = CheckedPlan.new(self, identification: identification)

    private

    # Who the answer is about when nobody was asked: only the payer's refusal can say anything.
    def nobody_compared = identify({})

    # The first person who matches, in the order `identify` describes.
    # Whether the person was asked about as a dependent is the caller's fact; it orders the comparison.
    # :reek:ControlParameter
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
