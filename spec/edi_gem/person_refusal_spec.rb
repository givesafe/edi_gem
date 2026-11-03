# frozen_string_literal: true

# What a payer said about the person when it refused, and the fields it named.
RSpec.describe EdiGem::PersonRefusal do
  def refused(level, code) = EdiGem::Rejection.new(level: level, code: code)

  describe ".among" do
    it "is the refusal about the person, in the subscriber's or the dependent's lane" do
      expect([described_class.among([refused(:subscriber, :date_of_birth_mismatch)]).reason,
              described_class.among([refused(:dependent, :name_mismatch)]).reason])
        .to eq(%i[date_of_birth_mismatch name_mismatch])
    end

    it "is nil WHEN the refusal is about the provider, or names a code it doesn't read" do
      expect([described_class.among([refused(:provider, :name_mismatch)]),
              described_class.among([refused(:subscriber, :input_errors)]), described_class.among([])])
        .to eq([nil, nil, nil])
    end

    it "is nil WHEN the birth date we sent is missing or malformed: the payer named no birth date it holds" do
      expect(described_class.among([refused(:subscriber, :invalid_date_of_birth)])).to be_nil
    end
  end

  describe "FINDINGS" do
    it "reads a birth date after the day asked and a dependent identifier the payer needs as what we sent" do
      expect(described_class::FINDINGS.values_at(:birth_date_after_day_asked, :dependent_id_required))
        .to eq(%i[our_fault our_fault])
    end

    it "reads a birth date missing or malformed as what we sent, and one held differently as the payer's" do
      expect(described_class::FINDINGS.values_at(:invalid_date_of_birth, :date_of_birth_mismatch))
        .to eq(%i[our_fault held_differently])
    end
  end

  describe ".refusal_among" do
    it "is the first refusal in the person's lanes that FINDINGS reads" do
      required = refused(:dependent, :dependent_id_required)

      expect(described_class.refusal_among([refused(:subscriber, :gender_missing), required])).to be(required)
    end
  end

  it "is mismatched WHEN the payer found the ID but not this person, and names the field it refused" do
    refusal = described_class.among([refused(:subscriber, :date_of_birth_mismatch)])

    expect([refusal.match, refusal.field_results])
      .to eq([:mismatched, { first_name: :not_returned, last_name: :not_returned, date_of_birth: :differs,
                             member_id: :not_returned }])
  end

  it "is not_compared WHEN the payer did not say the person differs" do
    refusal = described_class.among([refused(:subscriber, :subscriber_not_found)])

    expect([refusal.match, refusal.mismatch?, refusal.field_results.values.uniq])
      .to eq([:not_compared, false, [:not_returned]])
  end
end
