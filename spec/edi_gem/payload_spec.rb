# frozen_string_literal: true

# The dialect is what decides which Document can address into a body, so an unknown one is
# refused at construction rather than at the first read. A Payload built with a dialect nothing
# can parse would carry a vendor's response all the way to a Reading before failing, by which
# point the call has been billed and the bytes are in the payload store.
RSpec.describe EdiGem::Payload do
  it "refuses a dialect no document can read" do
    expect { described_class.new(body: "{}", dialect: :edifact) }
      .to raise_error(ArgumentError, /unknown dialect edifact/)
  end

  it "accepts the four the gem speaks" do
    expect(described_class::DIALECTS).to contain_exactly(:json, :x12, :soap, :mime)
  end

  it "takes a dialect written as a string, because a policy file supplies one" do
    expect(described_class.new(body: "{}", dialect: "json").dialect).to eq(:json)
  end

  it "keeps the body byte for byte" do
    expect(described_class.new(body: "  {}  ", dialect: :json).body).to eq("  {}  ")
  end
end
