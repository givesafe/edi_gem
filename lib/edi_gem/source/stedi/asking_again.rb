# frozen_string_literal: true

module EdiGem
  module Source
    class Stedi < Base
      # Asks again a payer that can't answer right now. Stedi says to ask again at once and keep
      # asking for up to two minutes (its eligibility troubleshooting guide, on payer connectivity),
      # and only while Response#ask_again? holds.
      #
      # The pauses are the seconds before each new ask. No ask starts, and no pause ends, once
      # WINDOW has passed since the first send, and the transport's own retries keep to the same
      # end. Each ask again gets a key of its own ("<key>-r1", "<key>-r2", ...), so the failed
      # answer can't come back for it.
      class AskingAgain
        PAUSES = [1, 5, 10, 20, 30, 30].freeze
        WINDOW = 120

        # `sleeper` waits and `clock` tells the time, injected so specs don't wait.
        def initialize(pauses: PAUSES, sleeper: Kernel, clock: Process)
          @pauses = pauses
          @sleeper = sleeper
          @clock = clock
        end

        # The first answer, or the last after asking again. The block sends one ask under the key
        # it is given and returns its Response; `retry_until` is when the transport stops retrying.
        def asked(key)
          retry_until = now + WINDOW
          response = yield(key, retry_until)
          @pauses.each.with_index(1) do |pause, retry_number|
            break unless response.ask_again? && now + pause < retry_until

            @sleeper.sleep(pause)
            response = yield("#{key}-r#{retry_number}", retry_until)
          end
          response
        end

        private

        def now = @clock.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
