# frozen_string_literal: true

module EdiGem
  # A refusal and the lane it came back in, which decides who has to act: transport and envelope
  # are the request's, provider is the provider's standing with the payer, subscriber is the
  # person's identifiers.
  class Rejection
    # `dependent` (loop 2100D) is kept as its own lane rather than folded into another.
    LEVELS = %i[transport envelope payer provider subscriber dependent].freeze

    # Reasons about the provider whatever loop carried them; payers do not always keep to the
    # lanes.
    PROVIDER_REASONS = %i[provider_not_on_file provider_not_eligible provider_not_authorized
                          provider_name_mismatch provider_phone_mismatch provider_state_mismatch
                          provider_not_primary_care provider_not_enrolled_on_date
                          provider_type_mismatch provider_address_invalid].freeze

    # The one reason Stedi says to ask again at once: the payer can't answer right now (AAA 42, or
    # 80 when no answer came back at all).
    RETRYABLE_REASON = :payer_unavailable
    NO_RESPONSE = "80"

    # AAA 79: Stedi had a problem connecting to the payer. Stedi doesn't bill it, and says not to
    # ask a 79 again on its own.
    CONNECTION_PROBLEM = :invalid_participant

    # The reasons Stedi's eligibility troubleshooting page reads as the payer's in another lane, by
    # that lane; Response and its state read one as they read its twin in the payer lane. In the
    # provider table, 79 is "There is a problem connecting with this payer. Contact Stedi support."
    # and T4 is the tradingPartnerName or tradingPartnerServiceId we sent, or "A payer processing
    # issue", neither a refusal of our provider. The subscriber and dependent tables give 42 the
    # payer table's resolution: with follow-up C, N or S "There is a problem with your request",
    # otherwise "The payer can't respond to your request". Its payer connectivity guidance names 42,
    # 80 and a 42 beside a 79 without naming a loop, so 42 and 80 (both :payer_unavailable) are the
    # payer's in each of these lanes.
    PAYER_REASONS_BY_LEVEL = {
      provider: [RETRYABLE_REASON, CONNECTION_PROBLEM, :payer_identifier_missing],
      subscriber: [RETRYABLE_REASON], dependent: [RETRYABLE_REASON]
    }.freeze

    # The AAA04 follow-up actions after which Stedi says not to ask a 42 again: the request itself
    # has a problem, which is a question for Stedi support. X12 sends the letter, Stedi's JSON the
    # words. Stedi makes no such exception for an 80.
    NOT_TO_RESUBMIT = ["C", "Please Correct and Resubmit", "N", "Resubmission Not Allowed",
                       "S", "Do Not Resubmit; Inquiry Initiated to a Third Party"].freeze

    # AAA 41 and T4, which Stedi reads as our setup, not the person: 41 our provider's NPI or tax ID,
    # or the payer portal's username or password; T4 the payer name or ID we sent.
    OUR_SETUP_REASONS = %i[authorization_restricted payer_identifier_missing].freeze

    # AAA04 as X12 writes it, one letter, by the words Stedi's JSON sends for it.
    FOLLOWUP_LETTERS = { "Please Correct and Resubmit" => "C", "Resubmission Not Allowed" => "N",
                         "Please Resubmit Original Transaction" => "P", "Resubmission Allowed" => "R",
                         "Do Not Resubmit; Inquiry Initiated to a Third Party" => "S",
                         "Please Wait 30 Days and Resubmit" => "W", "Please Wait 10 Days and Resubmit" => "X",
                         "Do Not Resubmit; We Will Hold Your Request and Respond Again Shortly" => "Y" }.freeze

    # A code as a payer or Stedi sends one: letters, digits and underscores, nothing longer.
    CODE_TEXT = /\A\w{1,40}\z/

    # The lane for the X12 loop a flattened error list names: A payer, B provider, C subscriber,
    # D dependent.
    LEVELS_BY_LOOP = { "2000A" => :payer, "2100A" => :payer,
                       "2000B" => :provider, "2100B" => :provider,
                       "2000C" => :subscriber, "2100C" => :subscriber,
                       "2000D" => :dependent, "2100D" => :dependent }.freeze
    LOOP = /\b(2[01]00[ABCD])\b/

    # `code` is the reason the codec named (a Symbol), or the AAA03 as sent when it named none;
    # `reason_code` is always the AAA03 as sent, since two codes can share one reason.
    attr_reader :level, :code, :reason_code, :description, :followup, :field, :location, :resolution

    def self.level_from(location)
      match = LOOP.match(location.to_s)
      match && LEVELS_BY_LOOP[match[1]]
    end

    def initialize(level:, code: nil, reason_code: nil, description: nil, followup: nil,
                   field: nil, location: nil, resolution: nil)
      raise ArgumentError, "unknown level #{level}" unless LEVELS.include?(level.to_sym)

      @level = level.to_sym
      @code = code
      @reason_code = reason_code
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

    # Whether the provider's standing with the payer is what was refused, by lane or by reason. A
    # reason Stedi reads as the payer's in the provider's lane is not (#about_payer?).
    def about_provider?
      (@level == :provider && !about_payer?) || PROVIDER_REASONS.include?(@code)
    end

    # Whether the payer refused our provider for want of our tax ID and address: our address invalid or
    # missing (AAA 97), or required data missing (AAA 15) in the provider's lane.
    def provider_details_wanted?
      @code == :provider_address_invalid || (@level == :provider && @code == :required_data_missing)
    end

    # Whether this is the payer's to read: anything in the payer lane, and in another lane a reason
    # Stedi reads as the payer's there (PAYER_REASONS_BY_LEVEL).
    def about_payer?
      @level == :payer || PAYER_REASONS_BY_LEVEL.fetch(@level, []).include?(@code)
    end

    # Whether Stedi says to ask again at once (its eligibility troubleshooting guide, on payer
    # connectivity): a payer that can't answer right now, unless a 42's follow-up says the request
    # must change first. An 80 is always asked again. Any other refusal is not, whatever its
    # follow-up says.
    def retryable? = @code == RETRYABLE_REASON && !resubmission_refused?

    # A 42 whose follow-up is C, N or S: Stedi says the payer refused the request as sent, which is
    # a problem with the request for Stedi support, not a payer that is down.
    def resubmission_refused?
      @code == RETRYABLE_REASON && @reason_code != NO_RESPONSE && NOT_TO_RESUBMIT.include?(@followup)
    end

    # The payer couldn't be reached: it can't answer right now (a 42 Stedi says to ask again, or an
    # 80), or Stedi had a problem connecting to it (79).
    def payer_unreached? = retryable? || @code == CONNECTION_PROBLEM

    # The payer refused our setup (OUR_SETUP_REASONS). Response reads it only where #about_payer?: a
    # T4 in the provider's lane counts, a 41 there is a refusal of our provider.
    def our_setup_refused? = OUR_SETUP_REASONS.include?(@code)

    # Whether the AAA03 sent is one X12 publishes (Codec::AAA03_VALUES), as Stedi's own refusals in a
    # failing HTTP status are.
    def aaa? = Codec::AAA03_VALUES.include?(@reason_code.to_s)

    # The refusal in codes alone, to record and log: "AAA 62 at subscriber, follow-up C". Never
    # Stedi's description or resolution, which are free text that may repeat what we sent about the
    # person. The AAA03 as sent, or the codec's reason when none came; a follow-up only as its letter.
    def summary
      letter = followup_letter
      [[reason_text, "at", @level].compact.join(" "), ("follow-up #{letter}" if letter)].compact.join(", ")
    end

    private

    def reason_text
      @reason_code.to_s.match?(CODE_TEXT) ? "AAA #{@reason_code}" : @code.to_s[CODE_TEXT]
    end

    # The letter itself, or the letter for Stedi's words; nil for anything else.
    def followup_letter
      FOLLOWUP_LETTERS.fetch(@followup) { @followup if FOLLOWUP_LETTERS.value?(@followup) }
    end
  end
end
