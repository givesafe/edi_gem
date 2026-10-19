# frozen_string_literal: true

module EdiGem
  # A refusal and the lane it came back in, which decides who has to act: transport and envelope
  # are the request's, provider is the provider's standing with the payer, subscriber is the
  # person's identifiers.
  class Rejection
    # `dependent` (loop 2100D) is kept as its own lane rather than folded into another.
    LEVELS = %i[transport envelope payer provider subscriber dependent].freeze

    # Reasons worth retrying whatever AAA04 says: a payer that is down often answers
    # "Resubmission Not Allowed".
    RETRYABLE_REASONS = %i[payer_unavailable].freeze

    # Reasons about the provider whatever loop carried them; payers do not always keep to the
    # lanes.
    PROVIDER_REASONS = %i[provider_not_on_file provider_not_eligible provider_not_authorized
                          provider_name_mismatch provider_phone_mismatch provider_state_mismatch
                          provider_not_primary_care provider_not_enrolled_on_date
                          provider_type_mismatch provider_address_invalid].freeze

    # AAA04 follow-up actions that say a later identical request may succeed.
    RETRYABLE_FOLLOWUPS = ["Please Resubmit Original Transaction", "Resubmission Allowed",
                           "Please Wait 30 Days and Resubmit", "Please Wait 10 Days and Resubmit",
                           "Do Not Resubmit; We Will Hold Your Request and Respond Again Shortly"].freeze

    # The lane for the X12 loop a flattened error list names: A payer, B provider, C subscriber,
    # D dependent.
    LEVELS_BY_LOOP = { "2000A" => :payer, "2100A" => :payer,
                       "2000B" => :provider, "2100B" => :provider,
                       "2000C" => :subscriber, "2100C" => :subscriber,
                       "2000D" => :dependent, "2100D" => :dependent }.freeze
    LOOP = /\b(2[01]00[ABCD])\b/

    attr_reader :level, :code, :description, :followup, :field, :location, :resolution

    def self.level_from(location)
      match = LOOP.match(location.to_s)
      match && LEVELS_BY_LOOP[match[1]]
    end

    def initialize(level:, code: nil, description: nil, followup: nil, field: nil,
                   location: nil, resolution: nil)
      raise ArgumentError, "unknown level #{level}" unless LEVELS.include?(level.to_sym)

      @level = level.to_sym
      @code = code
      @description = description
      @followup = followup
      @field = field
      @location = location
      @resolution = resolution
    end

    # Whether two entries describe the same refusal, regardless of lane.
    def same_refusal_as?(other)
      code == other.code && description == other.description && followup == other.followup
    end

    # Whether the provider's standing with the payer is what was refused, by lane or by reason.
    def about_provider?
      @level == :provider || PROVIDER_REASONS.include?(@code)
    end

    # False for any code the codec did not name, whatever its follow-up says: retrying a billed
    # check on a guess costs money.
    def retryable?
      return false unless recognised?

      RETRYABLE_REASONS.include?(@code) || RETRYABLE_FOLLOWUPS.include?(@followup)
    end

    # Whether the code decoded to a named reason (a Symbol) rather than a raw string.
    def recognised?
      @code.is_a?(Symbol)
    end
  end
end
