# frozen_string_literal: true

require "date"
require "net/http"
require "json"
require "digest"
require "uri"

module EdiGem
  module Source
    # Stedi's healthcare API: real-time eligibility, insurance discovery and batch eligibility.
    #
    # Uses net/http so the gem adds no runtime dependency. URLs, timeouts, retries and error
    # mapping come from data/sources.yml.
    #
    # Test and production share one host; the API key decides which is reached. Insurance
    # discovery always reports applicationMode "production", whatever the key.
    class Stedi < Base
      include Batching
      include Directory

      NAME = :stedi
      DISCOVERY_SCHEMA = :stedi_discovery

      # The feature an archived body is filed under. A discovery and its resolve share one.
      ELIGIBILITY_CHECK = :eligibility_check
      DISCOVERY = :discovery
      BATCH_CHECK = :batch_check
      BATCH_RESULT = :batch_result

      SEARCH_OPTIONS = [%i[member_id last_name date_of_birth],
                        %i[member_id last_name],
                        %i[first_name last_name date_of_birth]].freeze

      # `credential` holds the per-payer secrets (a portal username or password) for one
      # provider. `archive` defaults to the one EDI_ARCHIVE_TEMPLATE configures, or none.
      # `payer_pauses` replaces AskingAgain's pauses for a payer that can't answer right now (`[]`
      # asks once); `sleeper` and `clock` wait and tell the time, injected so specs don't wait.
      def initialize(api_key:, policy: Policy.for(NAME), transport: nil, credential: nil,
                     archive: Archive.from_env, payer_pauses: AskingAgain::PAUSES, sleeper: Kernel, clock: Process)
        super()
        raise ArgumentError, "api_key is required" if api_key.nil? || api_key.empty?

        @api_key = api_key
        @credential = credential
        @policy = policy
        @archive = archive
        @injected_transport = transport
        @asking_again = AskingAgain.new(pauses: payer_pauses, sleeper: sleeper, clock: clock)
        @transports = {}
      end

      def search_options
        SEARCH_OPTIONS
      end

      def capabilities
        { eligibility: true, discovery: true, batch: true }
      end

      # `archive:` is nil, or what to file the raw bodies under: `{ name: "stem" }` plus a value
      # for each placeholder the archive template leaves to the caller.
      #
      # `idempotency_key` overrides the key derived from the request. Stedi documents idempotency
      # keys for its claim and event endpoints, not for eligibility, so a key is no promise that a
      # repeat is answered without asking the payer again.
      #
      # A payer that can't answer right now is asked again as Stedi says (AskingAgain), each time
      # under a key of its own. The last answer is returned, the payer's or its last "can't answer".
      # The caller's key, when given, replaces the derived one, as in #post.
      # :reek:ControlParameter
      def eligibility(inquiry, idempotency_key: nil, archive: nil)
        ensure_searchable(inquiry)
        responses.ensure_archivable(archive)
        body = eligibility_body(inquiry)
        @asking_again.asked(idempotency_key || self.idempotency_key(:eligibility, body)) do |key, retry_until|
          exchange = post(:eligibility, body, key: key, retry_until: retry_until)
          responses.from(exchange, schema: NAME, feature: ELIGIBILITY_CHECK, archive: archive)
        end
      end

      # The request body, built without sending anything.
      def eligibility_body(inquiry)
        request(inquiry, payer_code: payer_code_for(inquiry)).eligibility
      end

      def discovery_body(inquiry)
        request(inquiry).discovery
      end

      # Answers synchronously when it can; otherwise returns a `pending` Response whose handle
      # is passed to #resolve.
      def discovery(inquiry, idempotency_key: nil, archive: nil)
        ensure_searchable(inquiry)
        responses.ensure_archivable(archive)
        exchange = post(:discovery, discovery_body(inquiry), key: idempotency_key)
        body = parse(exchange)
        responses.from(exchange, schema: DISCOVERY_SCHEMA, handle: body["discoveryId"],
                                 body: body, feature: DISCOVERY, archive: archive)
      end

      def resolve(handle, archive: nil)
        responses.ensure_archivable(archive)
        exchange = get(:discovery_results, "#{@policy.path_for(:discovery_results)}/#{handle}")
        responses.from(exchange, schema: DISCOVERY_SCHEMA, handle: handle, body: parse(exchange),
                                 feature: DISCOVERY, archive: archive)
      end

      # A discovery answer the archive kept (a Stored's response_uri), read again into a Response.
      # Nothing is sent to Stedi, so nothing is billed: the answer is the one already paid for.
      # Raises ArchiveNotConfigured with no archive, and ArchiveFailed when the body cannot be read:
      # `retryable?` is true when the archive could not be reached or answered that it is failing,
      # and false when the body is missing or refused, which asking again will not change.
      def archived_discovery(response_uri)
        raise ArchiveNotConfigured, "no archive is configured to read a discovery from" if @archive.nil?

        body = @archive.fetch(response_uri)
        exchange = Exchange.new(method: :get, url: response_uri, status: 200, response_body: body)
        parsed = Document::Json.parse(body)
        responses.from(exchange, schema: DISCOVERY_SCHEMA, handle: parsed["discoveryId"], body: parsed,
                                 feature: DISCOVERY)
      end

      private

      def responses
        @responses ||= Responses.new(archive: @archive, clearinghouse: NAME, directory: self, policy: @policy)
      end

      def request(inquiry, payer_code: nil)
        Request.new(inquiry, payer_code: payer_code, credential: @credential, policy: @policy)
      end

      def parse(exchange)
        Document::Json.parse(exchange.response_body)
      end

      # The caller's idempotency key overrides the one derived from the body. `key` is the
      # caller's `idempotency_key:` on #eligibility (which documents it), #discovery and
      # #submit_batch, passed through; old code's #post took it the same way, and old code is
      # add-only. `retry_until` (a Transport clock reading) is when the transport stops retrying.
      # :reek:ControlParameter
      def post(operation, body, key: nil, retry_until: nil)
        connection_for(operation).post(operation, JSON.generate(body),
                                       idempotency_key: key || idempotency_key(operation, body),
                                       retry_until: retry_until)
      end

      # Derived from the serialized request, so a retry above this gem sends the same key for the
      # same question. Stedi documents what a key does, kept 24 hours, for its claim and event
      # endpoints; its eligibility, discovery and batch pages don't mention one, so whether it
      # answers a repeated key without asking the payer again is not documented.
      def idempotency_key(operation, body)
        Digest::SHA256.hexdigest("#{operation}:#{JSON.generate(body)}")
      end

      def get(operation, path, query: nil)
        connection_for(operation).get(operation, path, query: query)
      end

      # Where an operation is sent. Every operation shares the one connection to Stedi.
      def connection_for(_operation)
        connection
      end

      def connection
        @connection ||= Connection.new(
          policy: @policy, transport: @injected_transport,
          headers: { "Authorization" => @api_key, "Content-Type" => "application/json" }
        )
      end
    end
  end
end
