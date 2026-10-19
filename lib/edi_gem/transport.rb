# frozen_string_literal: true

module EdiGem
  # The one place a failed exchange is handled: throttling, retries, and mapping failures to
  # Faults per the source's Policy. Nothing else in the gem rescues a transport error.
  class Transport
    def initialize(policy:, sleeper: Kernel, clock: Process, random: Kernel)
      @policy = policy
      @sleeper = sleeper
      @clock = clock
      @random = random
      @last_started_at = nil
    end

    # Runs one exchange, retrying per policy. The block returns the HTTP response; a failing
    # status becomes a Fault, raised once retries are exhausted.
    def perform(path:, &block)
      attempt = 0
      loop do
        attempt += 1
        pace
        response, fault = try(path, &block)
        return response if fault.nil?

        raise fault unless retry?(fault, attempt)

        @sleeper.sleep(delay_for(fault, attempt))
      end
    end

    private

    # One attempt, as a response or the Fault it turned into. The gem's own errors pass through.
    def try(path)
      response = yield
      [response, fault_for(response, path)]
    rescue EdiGem::Error
      raise # our own errors are results, not transport failures
    rescue StandardError => error
      [nil, from_exception(error, path)]
    end

    # Spaces requests to the policy's per-second rate.
    def pace
      per_second = @policy.throttle_per_second
      return if per_second.nil? || per_second.zero? || @last_started_at.nil?

      wait = (1.0 / per_second) - (now - @last_started_at)
      @sleeper.sleep(wait) if wait.positive?
    ensure
      @last_started_at = now
    end

    def now = @clock.clock_gettime(Process::CLOCK_MONOTONIC)

    def fault_for(response, path)
      return nil if response.is_a?(Net::HTTPSuccess)

      status = response.code.to_i
      Fault.new(kind: @policy.kind_for_status(status) || :unexpected, source: @policy.name,
                status: status, path: path, retry_after: retry_after(response))
    end

    def from_exception(error, path)
      Fault.new(kind: @policy.kind_for_exception(error), source: @policy.name, path: path,
                cause_class: error.class.name)
    end

    # A vendor's Retry-After wins over the policy's backoff.
    def retry_after(response)
      header = @policy.retry_after_header
      value = header && response[header]
      Integer(value, exception: false) if value
    end

    def retry?(fault, attempt)
      attempt < @policy.attempts && @policy.retry?(fault.kind)
    end

    def delay_for(fault, attempt)
      fault.retry_after || @policy.delay_before(attempt + 1, random: @random)
    end
  end
end
