# frozen_string_literal: true

module EdiGem
  # The secrets one provider holds with one source: an API key, a portal username and password,
  # or the envelope identifiers a clearinghouse assigns at enrolment. A bag of values rather than
  # fixed fields, because the set differs per source and per payer.
  class Credential
    attr_reader :provider, :source, :values, :enrolled_at

    # provider and source are nil only on .none.
    def initialize(provider:, source:, values: {}, enrolled_at: nil)
      @provider = provider
      @source = source&.to_sym
      @values = values
      @enrolled_at = enrolled_at
    end

    def [](key)
      @values[key.to_sym]
    end

    def enrolled?
      !@enrolled_at.nil?
    end

    # An empty credential, so a source need not branch on whether it was given one.
    def self.none
      new(provider: nil, source: nil)
    end

    # The required values, keyed by the field name the source sends each one as. Refuses a
    # partial set: a payer answers a missing credential as if the provider were not enrolled.
    def values_for(required, fields, payer: nil)
      return {} if required.empty?

      missing = required.reject { |key| self[key] }
      raise CredentialMissing, "#{payer} requires #{missing.join(", ")}, which we do not hold" if
        missing.any?

      required.to_h { |key| [fields.fetch(key), self[key]] }
    end

    def satisfies?(required)
      required.all? { |key| @values[key.to_sym].to_s != "" }
    end

    # Values are secrets; only their keys are printed.
    def inspect
      "#<#{self.class} #{@source} provider=#{@provider&.npi} #{@values.keys.join(",")}>"
    end
  end
end
