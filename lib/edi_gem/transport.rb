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
    # status becomes a Fault, raised once retries are exhausted, unless the policy says its body may
    # hold an answer (Policy#answer_in_status?): that response is returned to be read. `retry_until`,
    # a reading of this transport's clock, is when retrying stops: no retry starts after it, nor
    # waits past it.
    def perform(path:, retry_until: nil, &block)
      attempt = 0
      loop do
        attempt += 1
        pace
        response, fault = try(path, &block)
        return response if fault.nil?

        delay = retry_delay(fault, attempt, retry_until)
        raise fault if delay.nil?

        @sleeper.sleep(delay)
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
      return nil if @policy.answer_in_status?(status)

      Fault.of_status(status, policy: @policy, path: path, retry_after: retry_after(response))
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

    # The wait before the next attempt, or nil when none is due: out of attempts, a kind the policy
    # doesn't retry, or a wait that would end after `retry_until`. A kind the policy retries until
    # the end is out of attempts only at `retry_until`.
    # :reek:ControlParameter
    def retry_delay(fault, attempt, retry_until)
      kind = fault.kind
      return unless @policy.retry?(kind) && attempts_left?(kind, attempt, retry_until)

      delay = delay_for(fault, attempt)
      delay if retry_until.nil? || now + delay < retry_until
    end

    # :reek:ControlParameter
    def attempts_left?(kind, attempt, retry_until)
      attempt < @policy.attempts || (!retry_until.nil? && @policy.retry_until_end?(kind))
    end

    def delay_for(fault, attempt)
      fault.retry_after || @policy.delay_before(attempt + 1, random: @random)
    end
  end
end
