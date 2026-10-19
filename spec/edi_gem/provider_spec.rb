# frozen_string_literal: true

RSpec.describe EdiGem::Provider do
  # Without a name the request would look well-formed and be refused by the vendor.
  describe "a provider with no name" do
    it "refuses to be built" do
      expect { described_class.new(npi: "1999999984") }.to raise_error(ArgumentError)
    end

    it "says which field would satisfy it" do
      expect { described_class.new(npi: "1999999984") }
        .to raise_error(ArgumentError, /organization_name.*last_name/m)
    end

    # A required keyword alone would accept both of these, and both reach the wire as nothing.
    it "refuses an empty organization name" do
      expect { described_class.new(npi: "1999999984", organization_name: "") }
        .to raise_error(ArgumentError)
    end

    it "refuses an organization name that is only whitespace" do
      expect { described_class.new(npi: "1999999984", organization_name: "  ") }
        .to raise_error(ArgumentError)
    end
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

      expect(provider.to_h.keys).to_not include(:taxId, :medicaidProviderNumber)
    end
  end
end
