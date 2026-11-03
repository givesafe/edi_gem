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
end
