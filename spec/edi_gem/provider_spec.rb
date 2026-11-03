# frozen_string_literal: true

RSpec.describe EdiGem::Provider do
  # Stedi finds the provider by NPI and advises leaving the name out (Danny, 2026-10-31).
  it "is built from its NPI alone and sends only the NPI" do
    expect(described_class.new(npi: "1999999984").to_h).to eq(npi: "1999999984")
  end

  describe "#to_h" do
    it "sends an organisation under organizationName" do
      provider = described_class.new(npi: "1999999984", organization_name: "Example Clinic")

      expect(provider.to_h).to eq(npi: "1999999984", organizationName: "Example Clinic")
    end

    # An individual provider satisfies the same rule through the other field, which is what
    # NM1*1P's person form carries.
    it "accepts an individual named by last name instead" do
      provider = described_class.new(npi: "1999999984", last_name: "Example")

      expect(provider.to_h).to eq(npi: "1999999984", lastName: "Example")
    end

    it "omits every identifier the caller did not supply" do
      provider = described_class.new(npi: "1999999984", organization_name: "Example Clinic")

      expect(provider.to_h.keys).to_not include(:taxId, :address, :medicaidProviderNumber)
    end

    # Stedi: provider.taxId "Only include if required by the payer", provider.address "Only include when
    # specifically instructed by a payer". The caller decides when; the provider sends what it is given.
    it "sends a payer that needs them our tax ID under taxId and our address under address, as Stedi takes it" do
      address = EdiGem::Address.new(line1: "1 Example Way", line2: "Suite 2", city: "Los Angeles", state: "CA",
                                    postal_code: "90001")
      provider = described_class.new(npi: "1999999984", organization_name: "Example Clinic", tax_id: "000000000",
                                     address: address)

      expect(provider.to_h).to include(taxId: "000000000",
                                       address: { address1: "1 Example Way", address2: "Suite 2",
                                                  city: "Los Angeles", state: "CA", postalCode: "90001" })
    end

    it "sends no address WHEN none is given" do
      provider = described_class.new(npi: "1999999984", organization_name: "Example Clinic", address: nil)

      expect(provider.to_h).to_not have_key(:address)
    end
  end
end
