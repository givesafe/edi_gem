# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module EdiGem
  class Archive
    # S3 over net/http with SigV4, adding no runtime dependency. Uses virtual-hosted
    # addressing, so bucket names containing a dot are refused.
    class S3 < Archive
      CREDENTIAL_VARIABLES = %w[AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY].freeze

      # The answers AWS calls transient or throttling, so ArchiveFailed#retryable? is true for them:
      # 500, 502, 503 and 504 (503 is also S3's SlowDown) and 429. Every other answer, a missing
      # object (404 NoSuchKey, or 403 AccessDenied without s3:ListBucket) included, is not.
      # https://docs.aws.amazon.com/sdkref/latest/guide/feature-retry-behavior.html ("Which errors
      # are retried") and
      # https://docs.aws.amazon.com/AmazonS3/latest/userguide/optimizing-performance-design-patterns.html
      # (503 Slow Down). The status alone is read: the error body's code is not, so a 400
      # RequestTimeout is not retried.
      RETRYABLE_STATUSES = %w[429 500 502 503 504].freeze

      # The failures S3#reach recognizes, each raised as ArchiveFailed. NETWORK_ERRORS are the
      # timeouts, socket and connection errors, and IO errors Net::HTTP raises from the network (the
      # families it retries itself in Net::HTTP#transport_request), and are retryable.
      #
      # OpenSSL::SSL::SSLError is retryable by choice: a generic one does not say whether it will
      # pass, and Net::HTTP retries it for an idempotent request
      # (https://docs.ruby-lang.org/en/master/Net/HTTP.html#method-i-max_retries-3D). That is not
      # evidence that a TLS failure is transient; it is a cautious choice for a caller that retries
      # within a small budget.
      NETWORK_ERRORS = [Timeout::Error, SocketError, SystemCallError, IOError,
                        OpenSSL::SSL::SSLError].freeze

      # An answer Net::HTTP could not read as HTTP: a malformed status line, header or chunk
      # (HTTPBadResponse), or a malformed Content-Length or Content-Range (HTTPHeaderSyntaxError).
      # These are what Net::HTTP#request raises when the bytes that came back are not HTTP; nothing
      # says another attempt reads them differently, so they are not retryable.
      PROTOCOL_ERRORS = [Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError].freeze

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

      # Raises on any non-success answer rather than reporting a write that did not happen.
      def put(path, body)
        request = signed(Net::HTTP::Put, path, body: body, headers: { "content-type" => "application/json" })
        request.body = body
        succeeded(reach(request, path), path)
        location(path)
      end

      def fetch(uri)
        text = uri.to_s
        path = text.delete_prefix(location(""))
        # A uri this archive did not make is stored data, not a defect in the call: asking again
        # reads the same uri, so it is not retryable.
        raise ArchiveFailed, "#{uri} is not in s3://#{bucket}" if path == text

        succeeded(reach(signed(Net::HTTP::Get, path), path), path).body
      end

      private

      # Where this archive keeps `path`, as the uri it gives back.
      def location(path) = "s3://#{bucket}/#{path}"

      # A request of `verb` (a Net::HTTP request class) for `path`, signed for `body`.
      def signed(verb, path, body: "", headers: {})
        request = verb.new(URI.join(endpoint, "/#{path}"))
        @signature.headers_for(method: verb::METHOD.downcase.to_sym, uri: request.uri, body: body, headers: headers)
                  .each { |name, value| request[name] = value }
        request
      end

      # Raises ArchiveFailed for a failure in NETWORK_ERRORS (retryable) or PROTOCOL_ERRORS (not).
      # Any other exception, a TypeError or ArgumentError from a defect in the call included, is
      # not an archive failure and reaches the caller as it was raised.
      #
      # Timeout::Error covers Net::OpenTimeout, ReadTimeout and WriteTimeout; IOError covers
      # EOFError; SystemCallError covers Errno::ECONNRESET, ECONNREFUSED, ECONNABORTED,
      # EHOSTUNREACH, ETIMEDOUT and EPIPE.
      # Two rescue arms, and only one runs: each call happens once.
      # :reek:DuplicateMethodCall
      def reach(request, path)
        client.request(request)
      rescue *NETWORK_ERRORS => error
        raise ArchiveFailed.new("#{location(path)} could not be reached (#{error.class})", retryable: true)
      rescue *PROTOCOL_ERRORS => error
        raise ArchiveFailed.new("#{location(path)} answered with no readable HTTP (#{error.class})",
                                retryable: false)
      end

      # The response when it is a success; a non-success answer raises, retryable when its status is
      # in RETRYABLE_STATUSES.
      def succeeded(response, path)
        return response if response.is_a?(Net::HTTPSuccess)

        status = response.code
        raise ArchiveFailed.new("#{location(path)} answered #{status}",
                                retryable: RETRYABLE_STATUSES.include?(status.to_s))
      end

      # A dotted bucket name does not match AWS's wildcard certificate.
      def ensure_addressable
        raise ArgumentError, "a bucket name with a dot cannot be reached over TLS" if
          bucket.to_s.include?(".")
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
