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

    OUR_FAULT_LEVELS = %i[transport envelope].freeze
    NOT_IDENTIFIED_CODES = %i[member_id_invalid name_mismatch subscriber_not_found
                              patient_not_found date_of_birth_mismatch
                              duplicate_subscriber].freeze

    TEST_MODE = "test"

    attr_reader :benefits, :rejections, :payload, :exchanges, :handle, :details, :stored,
                :people

    # Who the payer answered about, and how they compare with who was asked about. `person` is
    # nil when the answer named nobody.
    Identification = Struct.new(:person, :result, keyword_init: true) do
      # The payer answered about the patient in the other part of the answer than asked: a
      # dependent asked as the subscriber, or the other way round.
      def moved?(as_dependent)
        !person.nil? && result.matched? && person.dependent? != as_dependent
      end
    end

    def initialize(benefits: [], rejections: [], payload: nil, exchanges: [], handle: nil,
                   state: nil, details: {}, settled: false, stored: nil, people: [])
      @benefits = benefits
      @rejections = rejections
      @people = people
      @payload = payload
      @exchanges = exchanges
      @handle = handle
      @state = state
      @details = details
      @settled = settled
      @stored = stored
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
      @state ||= derive_state
    end

    # The policyholder the answer names, or nil.
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
      order = [subscriber_person, *dependent_people].compact
      compared = (as_dependent ? order.rotate : order).map { |person| compared(person, asked, options) }
      compared.find { |found| found.result.matched? } || compared.first ||
        Identification.new(person: nil, result: Identity.compare(asked: asked, returned: {}))
    end

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
    def coverage_on(date)
      Coverage.on(@benefits, date)
    end

    private

    def compared(person, asked, options)
      Identification.new(person: person, result: Identity.compare(
        asked: asked, returned: person.identity, corrected: person.identity_corrected?, **options
      ))
    end

    # An empty answer with a handle is pending unless the source said it is settled; only a
    # settled empty answer is no_coverage.
    def derive_state
      return :pending if !@settled && @handle && @benefits.empty? && @rejections.empty?
      return :rejected if provider_refusals.any? || our_request_refused?
      return :not_identified if not_identified?
      return :payer_silent if payer_silent?
      return :no_coverage if benefit_lines.empty?
      return :partial if @rejections.any?

      :complete
    end

    def payer_silent?
      rejections_at(:payer).any? || (benefit_lines.empty? && @rejections.any?)
    end

    def benefit_lines
      @benefits.select(&:line?)
    end

    def our_request_refused?
      @rejections.any? { |rejection| OUR_FAULT_LEVELS.include?(rejection.level) }
    end

    # The patient may be the subscriber or a dependent of one; either one not found is the same.
    def not_identified?
      %i[subscriber dependent].flat_map { |level| rejections_at(level) }
                              .any? { |rejection| NOT_IDENTIFIED_CODES.include?(rejection.code) }
    end

    def concealed_inspect
      "#<#{self.class} #{state} benefits=#{@benefits.size} rejections=#{@rejections.size} " \
        "details=#{@details.keys.join(",")}>"
    end
  end
end
