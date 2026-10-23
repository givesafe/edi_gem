# frozen_string_literal: true

module EdiGem
  # One payer as a clearinghouse's payer directory lists it.
  #
  # `code` is the payer's primary code, the one an inquiry is routed with. `clearinghouse_id` is
  # the clearinghouse's own ID for it. `eligibility` is the clearinghouse's word for whether it
  # carries eligibility checks to this payer (Stedi's SUPPORTED, NOT_SUPPORTED,
  # ENROLLMENT_REQUIRED). Frozen: a listing is read, never changed.
  ListedPayer = Struct.new(:code, :clearinghouse_id, :aliases, :eligibility, keyword_init: true) do
    # As Stedi's payer search returns one, under "payer".
    def self.from_stedi(payer)
      new(code: payer["primaryPayerId"], clearinghouse_id: payer["stediId"], aliases: payer["aliases"] || [],
          eligibility: payer.dig("transactionSupport", "eligibilityCheck"))
    end

    def initialize(code:, clearinghouse_id: nil, aliases: [], eligibility: nil)
      super
      freeze
    end

    # Only a payer's own identifiers. A trade name is not a routing code, and a payer uses
    # different names for different lines of business.
    def answers_to?(wanted)
      ([code, clearinghouse_id] + aliases).compact.include?(wanted)
    end

    # Whether `wanted` is this payer's primary code, not only one it answers to.
    def code?(wanted) = code == wanted
  end
end
