# frozen_string_literal: true

module EdiGem
  # Who the payer answered about, and how they compare with who was asked about. `person` is
  # nil when the answer named nobody. `refusal` is the payer's PersonRefusal, which wins over
  # `result` (our comparison); `member_id_asked` whether the question named a member ID, as a
  # check does and a discovery does not. `given_fields` is how the details given beside the core
  # compare (Person::Asked#given_fields); they never change `result`.
  Identification = Struct.new(:person, :result, :refusal, :member_id_asked, :given_fields,
                              keyword_init: true) do
    # `person` compared with `asked` (Identity.compare's options); nobody compares with nothing.
    # `given_fields` are the given details' findings, worked out by the caller holding them.
    def self.of(person, asked, given_fields: {}, **options)
      new(person: person, given_fields: given_fields,
          result: Identity.compare(asked: asked, returned: person&.identity || {},
                                   corrected: person&.identity_corrected? || false, **options))
    end

    # The payer answered about the patient in the other part of the answer than asked: a
    # dependent asked as the subscriber, or the other way round.
    def moved?(as_dependent)
      !person.nil? && result.matched? && person.dependent? != as_dependent
    end

    # :matched, :mismatched or :not_compared. A loose match is a match.
    def match = refusal ? refusal.match : result.outcome

    def matched? = match == :matched

    # The payer answered about someone else: the person asked about may still be covered.
    def mismatched? = match == :mismatched

    # Each field (PersonRefusal::FIELDS): :matched, :differs or :not_returned. A member ID is
    # reported only when one was asked on, and only a payer's refusal says it differs.
    def fields
      return refusal.field_results if refusal

      member_id_asked ? result.fields.merge(member_id: :not_returned) : result.fields
    end

    # Each detail given beside the core (`address`, `ssn_last_four`), present only for the details
    # the question carried; a detail it left out has no key. Empty when it carried neither, as a
    # check's question never does. Each is one of:
    #   :matched       the question's and the payer's agree
    #   :differs       they disagree
    #   :not_compared  the question carried it in a form that can't be compared (a last four with
    #                  no four digits; an address without a first line or five postal digits)
    #   :not_returned  the question's can be compared, and the payer holds none to compare with
    def given_fields = self[:given_fields] || {}

    def differing = fields.select { |_, field| field == :differs }.keys

    # Why the person did not match: the refusal's reason, :identity_mismatch by our comparison,
    # or nil.
    def reason
      return refusal.reason if refusal

      :identity_mismatch if result.mismatched?
    end

    # :subscriber or :dependent, the part of the answer the compared person came back in; nil
    # when nobody was compared or the payer refused.
    def answered_as
      person.role if person && !refusal
    end
  end
end
