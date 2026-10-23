# frozen_string_literal: true

module EdiGem
  # What a payer said about the person when it refused (AAA03 in the subscriber or dependent
  # lane), and the fields it named. The payer's code wins over our comparison: a payer that
  # refuses names the part it refused.
  class PersonRefusal
    # Every field an identification reports on: the person's, and the member ID a check is sent on.
    FIELDS = (Identity::FIELDS + %i[member_id]).freeze

    LEVELS = %i[subscriber dependent].freeze

    attr_reader :reason, :fields

    # The refusal about the person among `rejections`, or nil. A refusal about the provider is not
    # one about the person.
    def self.among(rejections)
      about_person = rejections.find { |rejection| LEVELS.include?(rejection.level) && BY_CODE.key?(rejection.code) }
      BY_CODE[about_person.code] if about_person
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

    # The codes are the codec's: 71 and 58 (the dependent's) a birth date, 73 and 65 a name, 72
    # and 64 the member ID; 75 and 67 the subscriber not found, 77 the patient at neither level.
    BY_CODE = {
      date_of_birth_mismatch: new(reason: :date_of_birth_mismatch, fields: %i[date_of_birth], mismatch: true),
      name_mismatch: new(reason: :name_mismatch, fields: %i[first_name last_name], mismatch: true),
      member_id_invalid: new(reason: :member_id_invalid, fields: %i[member_id], mismatch: false),
      subscriber_not_found: new(reason: :not_found, fields: [], mismatch: false),
      patient_not_found: new(reason: :not_found, fields: [], mismatch: false)
    }.freeze
  end
end
