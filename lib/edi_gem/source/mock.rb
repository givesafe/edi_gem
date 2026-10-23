# frozen_string_literal: true

module EdiGem
  module Source
    # Stedi with insurance discovery answered from code, because Stedi's test mode answers no
    # discovery. Checks, batches and everything else go to Stedi with the key given.
    #
    # The person's last name picks the answer (see Scenario), and every answer Stedi documents for
    # discovery can be had, in Stedi's shapes and HTTP statuses: each Response state, a pending
    # discovery and what collecting it finds, and each HTTP failure. Only the socket is replaced:
    # the request is built, sent through the gem's own Transport (throttle, retries, faults), read
    # and archived as for Stedi. Every value in an answer is made up.
    #
    #   EdiGem::Source.for(:mock, api_key: key, payers: %w[11111 22222])
    class Mock < Stedi
      NAME = :mock

      # `payers` and `people` are Answers'. Every other keyword is Stedi's, and `transport:` serves
      # only what goes to Stedi: discovery always goes through the gem's own Transport.
      def initialize(payers: Answers::PAYERS, people: nil, **stedi)
        super(**stedi)
        @answers = Answers.new(payers: payers, people: people)
      end

      private

      # The mock answers discovery itself; every other operation goes to Stedi's connection.
      # `operation` is the argument of Stedi's own hook (#connection_for), which this overrides, and
      # the conditional is the one place a connection is selected (RAILS.md section 4).
      # :reek:ControlParameter
      def connection_for(operation)
        operation == :discovery ? discovery_connection : super
      end

      # The gem's own Transport, never an injected one, so throttling, retries and faults are what
      # Stedi's would be.
      def discovery_connection
        @discovery_connection ||= Connection.new(
          policy: @policy, client: Client.new(answers: @answers),
          headers: { "Authorization" => @api_key, "Content-Type" => "application/json" }
        )
      end
    end
  end
end
