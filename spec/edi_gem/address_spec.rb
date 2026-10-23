# frozen_string_literal: true

RSpec.describe EdiGem::Address do
  subject(:address) { described_class.new(line1: "1 Example St", city: "Example", state: "KY", postal_code: "40000") }

  it "is nil when made from no value" do
    expect(described_class.from(line1: nil, city: "")).to be_nil
  end

  it "keeps only the fields it holds" do
    expect(address.to_h).to eq(line1: "1 Example St", city: "Example", state: "KY", postal_code: "40000")
  end

  it "is sent as Stedi names the fields" do
    expect(address.to_stedi_h).to eq(address1: "1 Example St", city: "Example", state: "KY", postalCode: "40000")
  end

  it "prints which fields it holds, never their values" do
    expect(address.inspect).to eq("#<EdiGem::Address line1,city,state,postal_code>")
  end

  it "is read from Stedi's fields, and is nil from no fields or none at all" do
    read = described_class.from_stedi("address1" => "1 Example St", "city" => "Example", "postalCode" => "40000")

    expect([read.to_h, described_class.from_stedi({}), described_class.from_stedi(nil)])
      .to eq([{ line1: "1 Example St", city: "Example", postal_code: "40000" }, nil, nil])
  end

  # A proposed rule (O-20): the first line's words and the postal code's first five digits.
  describe "#compare" do
    def held(line1: "1 EXAMPLE ST.", postal_code: "40000-1234")
      described_class.new(line1: line1, postal_code: postal_code)
    end

    it "matches WHEN the first line's words and the first five digits agree, whatever the case, the city or a ZIP+4" do
      expect(address.compare(held)).to eq :matched
    end

    it "differs WHEN the first line does" do
      expect(address.compare(held(line1: "2 Example St"))).to eq :differs
    end

    it "differs WHEN the postal code does" do
      expect(address.compare(held(postal_code: "40001"))).to eq :differs
    end

    it "differs WHEN an abbreviation stands for the word" do
      expect(address.compare(held(line1: "1 Example Street"))).to eq :differs
    end

    it "ignores a second line, the city and the state" do
      other = described_class.new(line1: "1 Example St", line2: "Apt 2", city: "Elsewhere", state: "TN",
                                  postal_code: "40000")

      expect(address.compare(other)).to eq :matched
    end

    it "is not_returned WHEN ours has both parts and the payer holds no address, or lacks a line 1 or five digits" do
      expect([address.compare(nil), address.compare(held(line1: nil)), address.compare(held(postal_code: "400"))])
        .to all(eq :not_returned)
    end

    it "is not_compared WHEN ours lacks a first line or five digits, whatever the payer holds" do
      expect([described_class.new(city: "Example").compare(held), described_class.new(line1: "1 Example St",
                                                                                      postal_code: "400").compare(nil)])
        .to all(eq :not_compared)
    end
  end
end
