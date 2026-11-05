# frozen_string_literal: true

module EdiGem
  # What a payer's refusal in the subscriber's or dependent's lane (AAA03) says the answer found.
  module PersonRefusal
    LEVELS = %i[subscriber dependent].freeze

    # Which finding decides when the person's lanes hold several, whatever their order: a death,
    # then a refusal naming what the CTP can correct about the person, then what we sent.
    PRECEDENCE = %i[not_covered held_differently not_on_this_id our_fault].freeze

    # The refusal in the person's lanes that FINDINGS reads and PRECEDENCE puts first, or nil.
    # Response::State reads it to tell which state an answer is in, and which refusal decided it.
    def self.refusal_among(rejections)
      rejections.select { |rejection| LEVELS.include?(rejection.level) && FINDINGS.key?(rejection.code) }
                .min_by { |rejection| PRECEDENCE.index(FINDINGS[rejection.code]) }
    end

    # That refusal as [what it found, code], or nil.
    def self.finding_among(rejections)
      code = refusal_among(rejections)&.code
      [FINDINGS[code], code] if code
    end

    # What each refusal in the person's lanes (Codec::REJECT_REASON names) says the answer found:
    #   held_differently  the ID is found, the person under another birth date (71) or name (73, 65)
    #   not_on_this_id    not on the payer's books under this ID: invalid (72), not found (75, 67, 77),
    #                     more than one match (76, 68), or not in this group or plan (78)
    #   our_fault         what we sent: data missing (15), input errors (33), the day asked (56, 57, 62,
    #                     63), a birth date missing or malformed (58) or after the day asked (60), or a
    #                     dependent identifier the payer needs (64, as Stedi reads it), or a gender the
    #                     payer needs (74). Fixed by us, not by asking again
    #   not_covered       the person's date of death is before the day asked (61)
    # A code outside the table leaves the answer to its other refusals and lines.
    FINDINGS = {
      date_of_birth_mismatch: :held_differently, name_mismatch: :held_differently,
      member_id_invalid: :not_on_this_id, subscriber_not_found: :not_on_this_id,
      patient_not_found: :not_on_this_id, duplicate_subscriber: :not_on_this_id,
      subscriber_not_in_plan: :not_on_this_id,
      required_data_missing: :our_fault, input_errors: :our_fault,
      invalid_date_of_service: :our_fault, date_out_of_range: :our_fault,
      invalid_date_of_birth: :our_fault, birth_date_after_day_asked: :our_fault,
      dependent_id_required: :our_fault, gender_missing: :our_fault,
      date_of_death_conflict: :not_covered
    }.freeze
  end
end
