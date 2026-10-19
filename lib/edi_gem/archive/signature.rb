# frozen_string_literal: true

require "openssl"
require "digest"
require "time"
require "uri"

module EdiGem
  class Archive
    # AWS Signature Version 4 for S3, written out so the gem has no runtime dependencies.
    class Signature
      ALGORITHM = "AWS4-HMAC-SHA256"
      SERVICE = "s3"
      TERMINATOR = "aws4_request"

      def initialize(access_key_id:, secret_access_key:, region:, session_token: nil)
        @access_key_id = access_key_id
        @secret_access_key = secret_access_key
        @region = region
        @session_token = session_token
      end

      # The current instant in UTC, read from the realtime clock.
      def self.now
        Time.at(Process.clock_gettime(Process::CLOCK_REALTIME)).utc
      end

      # The headers to send, signature included. Host, payload hash and date are added and
      # signed.
      def headers_for(method:, uri:, body:, headers: {}, now: self.class.now)
        payload_hash = Digest::SHA256.hexdigest(body.to_s)
        signed = headers.merge(
          "host" => uri.host,
          "x-amz-content-sha256" => payload_hash,
          "x-amz-date" => now.strftime("%Y%m%dT%H%M%SZ")
        )
        signed["x-amz-security-token"] = @session_token if @session_token
        signed.merge("Authorization" => authorization(method, uri, signed, payload_hash, now))
      end

      private

      def authorization(method, uri, headers, payload_hash, now)
        scope = "#{now.strftime("%Y%m%d")}/#{@region}/#{SERVICE}/#{TERMINATOR}"
        canonical = canonical_request(method, uri, headers, payload_hash)
        to_sign = [ALGORITHM, headers["x-amz-date"], scope,
                   Digest::SHA256.hexdigest(canonical)].join("\n")
        signature = hmac(signing_key(now), to_sign).unpack1("H*")
        "#{ALGORITHM} Credential=#{@access_key_id}/#{scope}, " \
          "SignedHeaders=#{signed_headers(headers)}, Signature=#{signature}"
      end

      def canonical_request(method, uri, headers, payload_hash)
        [method.to_s.upcase, canonical_path(uri), uri.query.to_s,
         canonical_headers(headers), signed_headers(headers), payload_hash].join("\n")
      end

      # Each segment escaped once (S3 does not double-escape). The path is taken as raw, not
      # percent-encoded; Template::SAFE keeps every key the gem writes within that.
      def canonical_path(uri)
        uri.path.split("/", -1).map { |segment| escape(segment) }.join("/")
      end

      # Unreserved characters stay; everything else becomes upper-case %XX.
      def escape(segment)
        segment.gsub(/[^A-Za-z0-9\-._~]/) do |char|
          char.bytes.map { |byte| format("%%%02X", byte) }.join
        end
      end

      def canonical_headers(headers)
        sorted(headers).map { |name, value| "#{name}:#{value.to_s.strip}\n" }.join
      end

      def signed_headers(headers)
        sorted(headers).map(&:first).join(";")
      end

      def sorted(headers)
        headers.reject { |name, _| name.to_s.casecmp?("authorization") }
               .map { |name, value| [name.to_s.downcase, value] }.sort_by(&:first)
      end

      # One HMAC per scope part, each keyed on the last.
      def signing_key(now)
        [now.strftime("%Y%m%d"), @region, SERVICE, TERMINATOR]
          .reduce("AWS4#{@secret_access_key}") { |key, part| hmac(key, part) }
      end

      def hmac(key, value)
        OpenSSL::HMAC.digest("sha256", key, value)
      end
    end
  end
end
