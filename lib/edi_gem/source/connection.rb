# frozen_string_literal: true

require "net/http"
require "uri"

module EdiGem
  module Source
    # HTTP for a source: builds the request with the vendor's standing headers, sends it through
    # a Transport per operation, and records the Exchange verbatim.
    # An operation picks its policy; the path is per request (a discovery's handle).
    # :reek:DataClump
    class Connection
      include Concealed

      # `headers` are sent on every request (authorization, content type). `client` replaces the
      # Net::HTTP client, for a source that needs a prepared one (a client certificate).
      def initialize(policy:, headers: {}, transport: nil, client: nil)
        @policy = policy
        @headers = headers
        @injected_transport = transport
        @injected_client = client
        @transports = {}
      end

      def post(operation, body, idempotency_key: nil)
        path = @policy.path_for(operation)
        request = Net::HTTP::Post.new(url_for(operation, path))
        request.body = body
        request["Idempotency-Key"] = idempotency_key if idempotency_key
        send_request(request, operation, path)
      end

      # `query` is sent as the URL's query string; the Transport and any Fault name only `path`.
      def get(operation, path, query: nil)
        url = url_for(operation, path)
        url.query = URI.encode_www_form(query) if query
        send_request(Net::HTTP::Get.new(url), operation, path)
      end

      private

      # The host is per operation: an operation may override the source's base_url.
      def url_for(operation, path)
        URI.join(for_operation(operation).base_url, path)
      end

      def for_operation(operation)
        @operation_policies ||= {}
        @operation_policies[operation] ||= @policy.for_operation(operation)
      end

      # Transport owns rescue, status checks and retries.
      def send_request(request, operation, path)
        @headers.each { |name, value| request[name.to_s] = value }
        started_at = Time.now
        response = transport(operation).perform(path: path) { client(operation).request(request) }
        Exchange.from_http(request: request, response: response, started_at: started_at)
      end

      # One per operation, since timeouts and rate limits are per endpoint. An injected
      # transport serves every operation.
      def transport(operation)
        @injected_transport ||
          (@transports[operation] ||= Transport.new(policy: for_operation(operation)))
      end

      # A new client per request.
      def client(operation)
        return @injected_client if @injected_client

        uri = URI.parse(for_operation(operation).base_url)
        timeout = for_operation(operation).timeout
        Net::HTTP.new(uri.host, uri.port).tap do |http|
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = timeout
          http.read_timeout = timeout
        end
      end

      def concealed_inspect = "#<#{self.class} headers=#{@headers.keys.join(",")}>"
    end
  end
end
