# frozen_string_literal: true

module EdiGem
  # A failure to get an answer, in one vocabulary for every vendor; each vendor's failures are
  # mapped onto KINDS in data/sources.yml. A payer that answers "no" is a Rejection on a
  # Response, not a Fault.
  class Fault < RequestFailed
    # Every kind of failed exchange. `retryable` belongs to the kind, not the vendor.
    KINDS = {
      timeout: { retryable: true, level: :transport,
                 description: "the vendor did not answer in time" },
      unreachable: { retryable: true, level: :transport,
                     description: "the connection never established" },
      rate_limited: { retryable: true, level: :envelope,
                      description: "too many requests, retry after a delay" },
      vendor_unavailable: { retryable: true, level: :envelope,
                            description: "the vendor is failing, not refusing" },
      already_in_flight: { retryable: true, level: :envelope,
                           description: "an identical request is still being processed" },
      vendor_error: { retryable: false, level: :envelope,
                      description: "the vendor answered that it could not complete the request" },
      payer_unavailable: { retryable: true, level: :payer,
                           description: "the vendor reached the payer and the payer did not answer" },
      not_authorized: { retryable: false, level: :envelope,
                        description: "our credential was refused" },
      malformed_request: { retryable: false, level: :envelope,
                           description: "the vendor rejected the request as invalid" },
      unexpected: { retryable: false, level: :transport,
                    description: "a failure this gem has no row for" }
    }.freeze

    attr_reader :kind, :source, :status, :path, :retry_after, :cause_class

    # Never takes a response body: bodies hold PHI and errors get logged.
    def initialize(kind:, source: nil, status: nil, path: nil, retry_after: nil,
                   cause_class: nil)
      @kind = kind.to_sym
      raise ArgumentError, "unknown fault kind #{kind.inspect}" unless KINDS.key?(@kind)

      @source = source
      @status = status
      @path = path
      @retry_after = retry_after
      @cause_class = cause_class
      super(message_text)
    end

    def retryable? = KINDS.fetch(@kind)[:retryable]

    def level = KINDS.fetch(@kind)[:level]

    def description = KINDS.fetch(@kind)[:description]

    # The Rejection this fault stands for, so a failure can be recorded as a Response state.
    def to_rejection
      Rejection.new(level: level, code: @kind, description: description,
                    followup: retryable? ? "Resubmission Allowed" : nil)
    end

    private

    def message_text
      origin = @source || "source"
      parts = ["#{origin} #{@kind}: #{description}"]
      parts << "HTTP #{@status}" if @status
      parts << "at #{@path}" if @path
      parts << "retry after #{@retry_after}s" if @retry_after
      parts << "(#{@cause_class})" if @cause_class
      parts.join(" ")
    end
  end
end
