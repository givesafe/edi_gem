# frozen_string_literal: true

module EdiGem
  class Policy
    # What a caller may override on a Policy: the keys of the `retry` block of data/sources.yml.
    # Anything else is refused, so a misspelt setting is not silently ignored.
    module Override
      RETRY_KEYS = %w[attempts backoff multiplier max_delay jitter retry_on].freeze

      # The overrides in the shape of a source's attributes: string keys, one section deep.
      def self.sections(overrides)
        unknown = overrides.keys - [:retry]
        raise ArgumentError, "cannot override #{unknown.join(", ")}; only retry:" if unknown.any?

        { "retry" => retry_settings(overrides.fetch(:retry, {})) }
      end

      def self.retry_settings(settings)
        settings = settings.transform_keys(&:to_s)
        unknown = settings.keys - RETRY_KEYS
        raise ArgumentError, "unknown retry settings #{unknown.join(", ")}" if unknown.any?

        settings
      end
      private_class_method :retry_settings
    end
  end
end
