# frozen_string_literal: true

RSpec.describe EdiGem::ListedPayer do
  subject(:payer) do
    described_class.new(code: "99999", clearinghouse_id: "stedi-1", aliases: ["ALIAS1"])
  end

  it "answers to its primary code" do
    expect(payer.answers_to?("99999")).to be true
  end

  it "answers to its clearinghouse ID" do
    expect(payer.answers_to?("stedi-1")).to be true
  end

  it "answers to an alias" do
    expect(payer.answers_to?("ALIAS1")).to be true
  end

  it "answers to its code when the directory gave it no clearinghouse ID" do
    expect(described_class.new(code: "99999").answers_to?("99999")).to be true
  end

  it "knows its own code from one it only answers to" do
    expect([payer.code?("99999"), payer.code?("ALIAS1")]).to eq([true, false])
  end

  it "is frozen: a setter raises" do
    expect { payer.code = "88888" }.to raise_error(FrozenError)
  end

  describe ".from_stedi" do
    it "reads a payer as Stedi's directory lists it" do
      read = described_class.from_stedi(
        "stediId" => "stedi-99999", "primaryPayerId" => "99999", "displayName" => "EXAMPLE PAYER",
        "aliases" => ["ALIAS1"], "transactionSupport" => { "eligibilityCheck" => "ENROLLMENT_REQUIRED" }
      )

      expect([read.code, read.clearinghouse_id, read.aliases, read.eligibility])
        .to eq(["99999", "stedi-99999", ["ALIAS1"], "ENROLLMENT_REQUIRED"])
    end

    it "does not answer to the name the directory lists it by" do
      read = described_class.from_stedi("primaryPayerId" => "99999", "displayName" => "EXAMPLE PAYER")

      expect(read.answers_to?("EXAMPLE PAYER")).to be false
    end

    it "reads a payer listed with no aliases and no transaction support" do
      read = described_class.from_stedi("primaryPayerId" => "99999")

      expect([read.aliases, read.eligibility]).to eq([[], nil])
    end
  end
end
