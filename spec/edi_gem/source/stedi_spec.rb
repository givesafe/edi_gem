# frozen_string_literal: true

RSpec.describe EdiGem::Source::Stedi do
  subject(:stedi) { described_class.new(api_key: "test_key") }

  let(:provider) { EdiGem::Provider.new(npi: "1234567890", organization_name: "Example Clinic") }
  let(:subscriber) do
    EdiGem::Subscriber.new(member_id: "MEM123", first_name: "Ada", last_name: "Lovelace",
                           date_of_birth: "19151210")
  end

  def eligibility_inquiry(payer_code: "12345", **options)
    EdiGem::Inquiry::Eligibility.new(payer_code: payer_code, subscriber: subscriber,
                                     provider: provider, **options)
  end

  it_behaves_like "a source" do
    let(:source) { stedi }
    let(:inquiry) { eligibility_inquiry }
  end

  it "refuses to build without an api key" do
    expect { described_class.new(api_key: "") }.to raise_error(ArgumentError)
  end

  describe "the endpoints it will call" do
    let(:policy) { EdiGem::Policy.for(described_class::NAME) }

    it "addresses discovery under the dated prefix the other endpoints use" do
      expect(policy.path_for(:discovery)).to eq("/2024-04-01/insurance-discovery/check/v1")
    end

    it "waits out a discovery that takes the whole of the vendor's 120 seconds" do
      expect(policy.for_operation(:discovery).timeout).to be > 120
    end

    it "polls a discovery's results at the discovery's own path" do
      expect(policy.path_for(:discovery_results)).to eq(policy.path_for(:discovery))
    end

    it "waits out results that take the whole of the vendor's 120 seconds" do
      expect(policy.for_operation(:discovery_results).timeout).to be > 120
    end

    it "goes slower for discovery than for an eligibility check" do
      expect(policy.for_operation(:discovery).throttle_per_second)
        .to be < policy.for_operation(:eligibility).throttle_per_second
    end
  end

  # Without the required credential the request would go out short and be billed.
  describe "a payer that requires a portal credential" do
    let(:needing_pin) do
      eligibility_inquiry(payer_name: "Example State Medicaid",
                          required_credentials: [:portal_password])
    end
    let(:pin) do
      EdiGem::Credential.new(provider: provider, source: :stedi,
                             values: { portal_password: "0000" })
    end

    it "refuses to build the request at all when the credential is not held" do
      expect { stedi.eligibility_body(needing_pin) }
        .to raise_error(EdiGem::CredentialMissing,
                        /Example State Medicaid requires portal_password/)
    end

    it "names the payer by its code when the inquiry carries no name" do
      unnamed = eligibility_inquiry(required_credentials: [:portal_password])

      expect { stedi.eligibility_body(unnamed) }
        .to raise_error(EdiGem::CredentialMissing, /12345 requires portal_password/)
    end

    it "sends the PIN at the top level, which is where the schema puts it" do
      source = described_class.new(api_key: "test_key", credential: pin)

      expect(source.eligibility_body(needing_pin)[:portalPassword]).to eq("0000")
    end

    it "sends no portal username, because the payer wants only the PIN" do
      source = described_class.new(api_key: "test_key", credential: pin)

      expect(source.eligibility_body(needing_pin)).to_not have_key(:portalUsername)
    end

    it "asks nothing extra of a payer that requires nothing extra" do
      expect(stedi.eligibility_body(eligibility_inquiry)).to_not have_key(:portalPassword)
    end

    it "never prints the value, because a credential reaches a log the moment it is inspected" do
      expect(pin.inspect).to_not include("0000")
    end

    it "sends the inquiry's own credential in place of the source's" do
      source = described_class.new(api_key: "test_key", credential: pin)
      own = EdiGem::Credential.new(provider: provider, source: :stedi, values: { portal_password: "1111" })
      inquiry = eligibility_inquiry(required_credentials: [:portal_password], credential: own)

      expect(source.eligibility_body(inquiry)[:portalPassword]).to eq("1111")
    end
  end

  # Medi-Cal is declared in data/sources.yml, so the caller need not know it wants a PIN.
  describe "a payer the source knows requires a credential" do
    let(:medi_cal) { eligibility_inquiry(payer_code: "100065") }
    let(:pin) do
      EdiGem::Credential.new(provider: provider, source: :stedi, values: { portal_password: "0000" })
    end

    it "names what Medi-Cal requires" do
      expect(stedi.required_credentials("100065")).to eq([:portal_password])
    end

    it "requires nothing of a payer it has no entry for" do
      expect(stedi.required_credentials("12345")).to eq([])
    end

    it "refuses to build the request when the inquiry names no credential" do
      expect { stedi.eligibility_body(medi_cal) }
        .to raise_error(EdiGem::CredentialMissing, /100065 requires portal_password/)
    end

    it "sends the PIN the inquiry carries" do
      inquiry = eligibility_inquiry(payer_code: "100065", credential: pin)

      expect(stedi.eligibility_body(inquiry)[:portalPassword]).to eq("0000")
    end

    it "refuses a batch item short of the PIN before anything is sent" do
      expect { stedi.submit_batch([medi_cal]) }.to raise_error(EdiGem::CredentialMissing)
    end
  end

  describe "#discovery_body" do
    let(:discovery) do
      EdiGem::Inquiry::Discovery.new(subscriber: subscriber, provider: provider,
                                     as_of: Date.new(2026, 9, 3))
    end

    it "carries the service date range discovery requires" do
      expect(stedi.discovery_body(discovery)[:encounter])
        .to eq(beginningDateOfService: "20260903", endDateOfService: "20260903",
               serviceTypeCodes: ["30"])
    end
  end

  describe "#eligibility_body" do
    it "addresses the payer by the code the inquiry carries" do
      expect(stedi.eligibility_body(eligibility_inquiry)[:tradingPartnerServiceId]).to eq("12345")
    end

    it "sends no date of service when the inquiry did not ask for one" do
      expect(stedi.eligibility_body(eligibility_inquiry)[:encounter])
        .to eq(serviceTypeCodes: ["30"])
    end

    it "sends the date of service the inquiry did ask for, as X12's YYYYMMDD" do
      dated = eligibility_inquiry(as_of: Date.new(2026, 9, 3))

      expect(stedi.eligibility_body(dated)[:encounter])
        .to eq(serviceTypeCodes: ["30"], dateOfService: "20260903")
    end

    it "sends a suffix in its own field and no title, as Stedi asks" do
      suffixed = EdiGem::Subscriber.new(member_id: "MEM123", first_name: "Dr Ada", last_name: "Lovelace Jr.",
                                        date_of_birth: "19151210")
      inquiry = EdiGem::Inquiry::Eligibility.new(payer_code: "12345", subscriber: suffixed, provider: provider)

      expect(stedi.eligibility_body(inquiry)[:subscriber])
        .to include(firstName: "ADA", lastName: "LOVELACE", suffix: "JR")
    end

    it "sends no suffix WHEN the last name has none" do
      expect(stedi.eligibility_body(eligibility_inquiry)[:subscriber]).to_not have_key(:suffix)
    end

    it "raises PayerNotRouted when the inquiry carries no payer code" do
      expect { stedi.eligibility_body(eligibility_inquiry(payer_code: "  ")) }
        .to raise_error(EdiGem::PayerNotRouted, /no payer code for stedi/)
    end

    it "raises PayerNotRouted for a nil payer code too" do
      expect { stedi.eligibility_body(eligibility_inquiry(payer_code: nil)) }
        .to raise_error(EdiGem::PayerNotRouted)
    end
  end

  describe "#search_options" do
    it "declares combinations rather than a single required set" do
      expect(stedi.search_options).to include(%i[first_name last_name date_of_birth])
    end
  end

  describe "#capabilities" do
    it "supports every feature in the contract" do
      expect(stedi.capabilities).to eq(eligibility: true, discovery: true, batch: true)
    end
  end
end
