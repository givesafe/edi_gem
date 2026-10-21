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

    attr_reader :benefits, :rejections, :payload, :exchanges, :handle, :details, :stored

    def initialize(benefits: [], rejections: [], payload: nil, exchanges: [], handle: nil,
                   state: nil, details: {}, settled: false, stored: nil)
      @benefits = benefits
      @rejections = rejections
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

    def rejections_at(level)
      @rejections.select { |rejection| rejection.level == level }
    end

    def provider_refusals
      @rejections.select(&:about_provider?)
    end

    def active_benefits
      @benefits.select(&:active?)
    end

    private

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

    def not_identified?
      rejections_at(:subscriber).any? { |rejection| NOT_IDENTIFIED_CODES.include?(rejection.code) }
    end

    def concealed_inspect
      "#<#{self.class} #{state} benefits=#{@benefits.size} rejections=#{@rejections.size} " \
        "details=#{@details.keys.join(",")}>"
    end
  end
end
