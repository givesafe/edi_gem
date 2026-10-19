# frozen_string_literal: true

RSpec.describe EdiGem::Credential do
  subject(:credential) do
    described_class.new(provider: provider, source: :stedi, values: { api_key: "sk_live_x" })
  end

  let(:provider) { EdiGem::Provider.new(npi: "1234567890", organization_name: "Example Clinic") }

  it "reads a value by key" do
    expect(credential[:api_key]).to eq("sk_live_x")
  end

  describe "#satisfies?" do
    it "is true when every required key is filled" do
      expect(credential.satisfies?(%i[api_key])).to be(true)
    end

    it "is false when a required key is missing" do
      expect(credential.satisfies?(%i[api_key submitter_pin])).to be(false)
    end

    it "treats an empty string as unfilled" do
      blank = described_class.new(provider: provider, source: :medi_cal, values: { pin: "" })

      expect(blank.satisfies?(%i[pin])).to be(false)
    end
  end

  describe "#enrolled?" do
    it "is false until a trading partner agreement has been recorded" do
      expect(credential).not_to be_enrolled
    end

    it "is true once one has" do
      enrolled = described_class.new(provider: provider, source: :office_ally,
                                     enrolled_at: Time.now)

      expect(enrolled).to be_enrolled
    end
  end

  it "names the keys it holds" do
    expect(credential.inspect).to include("api_key")
  end

  it "never prints the secret behind a key" do
    expect(credential.inspect).not_to include("sk_live_x")
  end
end
