# frozen_string_literal: true

module EdiGem
  # What a payer said about the person when it refused (AAA03 in the subscriber or dependent
  # lane), and the fields it named. The payer's code wins over our comparison: a payer that
  # refuses names the part it refused.
  class PersonRefusal
    # Every field a payer's refusal can name: the person's, and the member ID a check is sent on.
    FIELDS = (Identity::FIELDS + %i[member_id]).freeze

    LEVELS = %i[subscriber dependent].freeze

    attr_reader :reason, :fields

    # The refusal about the person among `rejections`, or nil. A refusal about the provider is not
    # one about the person.
    def self.among(rejections)
      about_person = rejections.find { |rejection| LEVELS.include?(rejection.level) && BY_CODE.key?(rejection.code) }
      BY_CODE[about_person.code] if about_person
    end

    # The first refusal in the person's lanes that FINDINGS reads, or nil. Response::State reads it
    # to tell which state an answer is in, and which refusal decided it.
    def self.refusal_among(rejections)
      rejections.find { |rejection| LEVELS.include?(rejection.level) && FINDINGS.key?(rejection.code) }
    end

    # That refusal as [what it found, code], or nil.
    def self.finding_among(rejections)
      code = refusal_among(rejections)&.code
      [FINDINGS[code], code] if code
    end

    def initialize(reason:, fields:, mismatch:)
      @reason = reason
      @fields = fields
      @mismatch = mismatch
    end

    # The payer found the ID but not this person, so the person may still be covered.
    def mismatch? = @mismatch

    # :mismatched, or :not_compared when the payer did not say the person differs.
    def match = mismatch? ? :mismatched : :not_compared

    # Each field: differs when the payer named it, not_returned otherwise.
    def field_results
      FIELDS.to_h { |field| [field, fields.include?(field) ? :differs : :not_returned] }
    end

    # The codes are the codec's: 71 a birth date, 73 and 65 a name, 72 the
    # member ID; 75 and 67 the subscriber not found, 77 the patient at neither level.
    BY_CODE = {
      date_of_birth_mismatch: new(reason: :date_of_birth_mismatch, fields: %i[date_of_birth], mismatch: true),
      name_mismatch: new(reason: :name_mismatch, fields: %i[first_name last_name], mismatch: true),
      member_id_invalid: new(reason: :member_id_invalid, fields: %i[member_id], mismatch: false),
      subscriber_not_found: new(reason: :not_found, fields: [], mismatch: false),
      patient_not_found: new(reason: :not_found, fields: [], mismatch: false)
    }.freeze

    # What each refusal in the person's lanes (Codec::REJECT_REASON names) says the answer found:
    #   held_differently  the ID is found, the person under another birth date (71) or name (73, 65)
    #   not_on_this_id    not on the payer's books under this ID: invalid (72), not found (75, 67, 77),
    #                     more than one match (76, 68), or not in this group or plan (78)
    #   our_fault         what we sent: data missing (15), input errors (33), the day asked (56, 57, 62,
    #                     63), a birth date missing or malformed (58) or after the day asked (60), or a
    #                     dependent identifier the payer needs (64, as Stedi reads it). Fixed by us, not
    #                     by asking again
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
      dependent_id_required: :our_fault,
      date_of_death_conflict: :not_covered
    }.freeze
  end
end
