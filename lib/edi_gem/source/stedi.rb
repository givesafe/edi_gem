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
      NAME = :stedi
      DISCOVERY_SCHEMA = :stedi_discovery

      # The feature an archived body is filed under. A discovery and its resolve share one.
      ELIGIBILITY_CHECK = :eligibility_check
      DISCOVERY = :discovery
      BATCH_CHECK = :batch_check

      SEARCH_OPTIONS = [%i[member_id last_name date_of_birth],
                        %i[member_id last_name],
                        %i[first_name last_name date_of_birth]].freeze

      # `credential` holds the per-payer secrets (a portal username or password) for one
      # provider. `archive` defaults to the one EDI_ARCHIVE_TEMPLATE configures, or none.
      def initialize(api_key:, policy: Policy.for(NAME), transport: nil, credential: nil,
                     archive: Archive.from_env)
        super()
        raise ArgumentError, "api_key is required" if api_key.nil? || api_key.empty?

        @api_key = api_key
        @credential = credential
        @policy = policy
        @archive = archive
        @injected_transport = transport
        @transports = {}
      end

      def search_options
        SEARCH_OPTIONS
      end

      def capabilities
        { eligibility: true, discovery: true, batch: true }
      end

      # Up to 10,000 checks in one request, answered with a batch id. The price per check is the
      # same as a real-time check.
      #
      # `max_retry_hours` is how long Stedi keeps retrying a payer that does not respond (8 by
      # default, up to 24); a batch is not finished until that window closes.
      def submit_batch(inquiries, name: nil, idempotency_key: nil, max_retry_hours: nil)
        items = Batch.keyed(inquiries).map { |id, inquiry| batch_item(id, inquiry) }
        body = { items: items, name: name, maxRetryHours: max_retry_hours }.compact
        exchange = post(:batch_eligibility, body, key: idempotency_key)
        Batch::Submission.from(parse(exchange), count: items.length, exchange: exchange)
      end

      def batch_status(batch_id)
        exchange = get(:batch_status, "#{@policy.path_for(:batch_status)}/#{batch_id}")
        Batch::Status.from(parse(exchange), exchange: exchange)
      end

      # Every check in the batch, in whatever state each is in, including checks that failed
      # validation. A nil `next_page_token` is the only sign the listing is complete.
      def batch_checks(batch_id, page_token: nil, page_size: nil)
        query = { pageToken: page_token, pageSize: page_size }.compact
        path = "#{@policy.path_for(:batch_checks)}/#{batch_id}/items"
        exchange = get(:batch_checks, query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}")
        Batch::Checks.from(parse(exchange), exchange: exchange)
      end

      # `archive:` is nil, or what to file the raw bodies under: `{ name: "stem" }` plus a value
      # for each placeholder the archive template leaves to the caller.
      #
      # `idempotency_key` overrides the key derived from the request; pass one to force a fresh
      # check of something already asked within Stedi's 24-hour idempotency window.
      def eligibility(inquiry, idempotency_key: nil, archive: nil)
        ensure_searchable(inquiry)
        responses.ensure_archivable(archive)
        exchange = post(:eligibility, eligibility_body(inquiry), key: idempotency_key)
        responses.from(exchange, schema: NAME, feature: ELIGIBILITY_CHECK, archive: archive)
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
        exchange = get(:discovery, "#{@policy.path_for(:discovery)}/#{handle}")
        responses.from(exchange, schema: DISCOVERY_SCHEMA, handle: handle, body: parse(exchange),
                                 feature: DISCOVERY, archive: archive)
      end

      private

      def responses
        @responses ||= Responses.new(archive: @archive, clearinghouse: NAME)
      end

      def request(inquiry, payer_code: nil)
        Request.new(inquiry, payer_code: payer_code, credential: @credential)
      end

      def batch_item(identifier, inquiry)
        ensure_searchable(inquiry)
        request(inquiry, payer_code: payer_code_for(inquiry)).batch_item(identifier)
      end

      def parse(exchange)
        Document::Json.parse(exchange.response_body)
      end

      def post(operation, body, key: nil)
        connection.post(operation, JSON.generate(body),
                        idempotency_key: key || idempotency_key(operation, body))
      end

      # Derived from the serialized request, so a retry above this gem asks the same billable
      # question rather than a new one. Stedi remembers a key for 24 hours.
      def idempotency_key(operation, body)
        Digest::SHA256.hexdigest("#{operation}:#{JSON.generate(body)}")
      end

      def get(operation, path)
        connection.get(operation, path)
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
