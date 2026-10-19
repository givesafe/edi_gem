# frozen_string_literal: true

require "net/http"
require "uri"

module EdiGem
  class Archive
    # S3 over net/http with SigV4, adding no runtime dependency. Uses virtual-hosted
    # addressing, so bucket names containing a dot are refused.
    class S3 < Archive
      CREDENTIAL_VARIABLES = %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

      # Nil when the AWS credentials are absent.
      def self.from_env(template:, env: ENV)
        return nil unless CREDENTIAL_VARIABLES.all? { |name| env[name] }

        new(template: template,
            region: env["AWS_REGION"] || env["AWS_DEFAULT_REGION"] || "us-east-1",
            access_key_id: env.fetch("AWS_ACCESS_KEY_ID"),
            secret_access_key: env.fetch("AWS_SECRET_ACCESS_KEY"),
            session_token: env["AWS_SESSION_TOKEN"])
      end

      attr_reader :region

      def initialize(template:, region:, access_key_id:, secret_access_key:,
                     session_token: nil, timeout: 30, client: nil)
        super(template: template)
        ensure_addressable
        @region = region
        @timeout = timeout
        @client = client
        @signature = Signature.new(access_key_id: access_key_id, region: region,
                                   secret_access_key: secret_access_key,
                                   session_token: session_token)
      end

      def bucket = template.bucket

      def endpoint
        @endpoint ||= URI.parse("https://#{bucket}.s3.#{@region}.amazonaws.com")
      end

      def put(path, body)
        uri = URI.join(endpoint, "/#{path}")
        request = Net::HTTP::Put.new(uri)
        request.body = body
        @signature.headers_for(method: :put, uri: uri, body: body,
                               headers: { "content-type" => "application/json" })
                  .each { |name, value| request[name] = value }
        answer(reach(request, path), path)
      end

      private

      # A network failure is raised as ArchiveFailed, like a refused write.
      def reach(request, path)
        client.request(request)
      rescue StandardError => error
        raise ArchiveFailed, "s3://#{bucket}/#{path} could not be reached (#{error.class})"
      end

      # A dotted bucket name does not match AWS's wildcard certificate.
      def ensure_addressable
        raise ArgumentError, "a bucket name with a dot cannot be reached over TLS" if
          bucket.to_s.include?(".")
      end

      # Raises on any non-success answer rather than reporting a write that did not happen.
      def answer(response, path)
        return "s3://#{bucket}/#{path}" if response.is_a?(Net::HTTPSuccess)

        raise ArchiveFailed, "s3://#{bucket}/#{path} answered #{response.code}"
      end

      def client
        @client ||= Net::HTTP.new(endpoint.host, endpoint.port).tap do |http|
          http.use_ssl = true
          http.open_timeout = @timeout
          http.read_timeout = @timeout
        end
      end
    end
  end
end
