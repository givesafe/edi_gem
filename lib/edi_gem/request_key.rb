# frozen_string_literal: true

require "json"
require "openssl"

module EdiGem
  # Two keys made from what a question asks, so the details themselves are never stored or sent.
  # Never log a key beside a person's details.
  #
  # `secret` is the caller's, one for each kind of key, so neither shares a secret with another
  # use. Case, spacing and blank details don't change a key.
  module RequestKey
    OPERATIONS = %i[eligibility discovery batch].freeze
    SPACE = /[[:space:]]+/

    module_function

    # The same details give the same fingerprint on any day, so a later question can tell nothing
    # has changed.
    def fingerprint(details, secret:)
      normalized = details.to_h { |name, value| [name.to_s, normalize(value)] }.reject { |_name, value| value.empty? }
      OpenSSL::HMAC.hexdigest("SHA256", secret, JSON.generate(normalized.sort.to_h))
    end

    # The same operation and details on the same day give the same key, sent as the Idempotency-Key
    # header. Stedi documents no idempotency key for eligibility or discovery, so the caller keeping
    # one question to one key a day is what keeps it paid for once. `on` is the caller's today, in
    # the caller's time zone.
    def idempotency_key(operation, details, secret:, on:)
      raise ArgumentError, "unknown operation #{operation}" unless OPERATIONS.include?(operation.to_sym)

      fingerprint(details.merge(operation: operation, day: on), secret: secret)
    end

    # A detail as text: a Date's is its ISO 8601 day.
    def normalize(value) = value.to_s.gsub(SPACE, " ").strip.downcase
    private_class_method :normalize
  end
end
