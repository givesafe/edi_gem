# frozen_string_literal: true

# What a payer's refusal in the person's lanes says the answer found.
RSpec.describe EdiGem::PersonRefusal do
  def refused(level, code) = EdiGem::Rejection.new(level: level, code: code)

  describe "FINDINGS" do
    it "reads a birth date after the day asked and a dependent identifier the payer needs as what we sent" do
      expect(described_class::FINDINGS.values_at(:birth_date_after_day_asked, :dependent_id_required))
        .to eq(%i[our_fault our_fault])
    end

    it "reads a gender the payer needs as what we sent, as Stedi says to correct and resubmit" do
      expect(described_class::FINDINGS[:gender_missing]).to eq(:our_fault)
    end

    it "reads a birth date missing or malformed as what we sent, and one held differently as the payer's" do
      expect(described_class::FINDINGS.values_at(:invalid_date_of_birth, :date_of_birth_mismatch))
        .to eq(%i[our_fault held_differently])
    end
  end

  describe ".refusal_among" do
    it "is the first refusal in the person's lanes that FINDINGS reads" do
      required = refused(:dependent, :dependent_id_required)

      expect(described_class.refusal_among([refused(:subscriber, :out_of_network), required])).to be(required)
    end
  end
end
