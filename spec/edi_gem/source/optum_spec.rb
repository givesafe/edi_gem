# frozen_string_literal: true

# Optum, a stub written from the vendor's published material and never called. The endpoint,
# envelope form and authentication are assumptions; these specs pin what the source sends, not
# what Optum answers.
RSpec.describe EdiGem::Source::Optum do
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC") }
  let(:subscriber) do
    EdiGem::Subscriber.new(member_id: "MEM123", last_name: "LOVELACE", date_of_birth: "19800101")
  end

  def inquiry(person: subscriber, provider: self.provider)
    EdiGem::Inquiry::Eligibility.new(payer_code: "OPT01", payer_name: "EXAMPLE HEALTH PLAN",
                                     subscriber: person, provider: provider)
  end

  it_behaves_like "a source" do
    let(:source) { described_class.new(credential: optum_credential) }
  end

  def optum_credential(**overrides)
    enrolled(:optum, receiver_id: "OPTUM", application_receiver: "OPTUM", **overrides)
  end

  describe "what it says it can do" do
    subject(:source) { described_class.new(credential: optum_credential) }

    it "offers eligibility and not discovery" do
      expect(source.capabilities).to include(eligibility: true, discovery: false)
    end

    it "claims no batch lane" do
      expect(source.capabilities[:batch]).to be(false)
    end
  end

  # Assumed: the implementation guide's primary search options.
  describe "the identifiers it will match on" do
    subject(:source) { described_class.new(credential: optum_credential) }

    it "takes the standard's minimum, which Office Ally narrows and this does not" do
      expect(source.search_options.first).to eq(%i[member_id last_name date_of_birth])
    end

    it "accepts a name and birth date with an SSN, which the standard allows" do
      by_ssn = EdiGem::Subscriber.new(first_name: "ADA", last_name: "LOVELACE",
                                      date_of_birth: "19800101", ssn: "123456789")

      expect(source.search_options.any? { |option| inquiry(person: by_ssn).satisfies?([option]) })
        .to be(true)
    end
  end

  # No default receiver is published, so none is invented.
  it "invents no default receiver, because none is published" do
    expect(described_class::RECEIVER).to be_nil
  end

  describe "the request it builds" do
    subject(:body) do
      source = described_class.new(credential: optum_credential, now: Time.at(0))
      source.send(:request_body, inquiry, trace: "T1")
    end

    # Assumed: no connectivity guide says which envelope form Optum takes.
    it "sends bare X12 rather than a CORE envelope" do
      expect(body).to start_with("ISA*00*")
    end

    it "routes on the payer code the inquiry carries" do
      expect(body).to include("PI*OPT01")
    end

    it "addresses the receiver the credential assigned rather than a default" do
      expect(body).to include("ZZ*OPTUM")
    end

    it "is a complete interchange, ISA through IEA" do
      expect(body).to end_with("IEA*1*000000001~")
    end
  end

  describe "before the connection is established" do
    it "refuses to send without an endpoint" do
      source = described_class.new(credential: optum_credential(endpoint: nil))

      expect { source.eligibility(inquiry) }
        .to raise_error(EdiGem::CredentialMissing, /optum needs the endpoint/)
    end
  end

  it "refuses to archive, because it keeps no bodies" do
    source = described_class.new(credential: optum_credential)

    expect { source.eligibility(inquiry, archive: { name: "x" }) }
      .to raise_error(EdiGem::FeatureNotSupported, /does not archive/)
  end

  it "refuses an inquiry with no payer code before sending" do
    source, transport = x12_answering(described_class, answering(functional_acknowledgement),
                                      receiver_id: "OPTUM", application_receiver: "OPTUM")
    blank = EdiGem::Inquiry::Eligibility.new(payer_code: "", subscriber: subscriber,
                                             provider: provider)

    expect { source.eligibility(blank) }.to raise_error(EdiGem::PayerNotRouted, /optum/)
    expect(transport.paths).to be_empty
  end

  describe "reading what comes back" do
    it "reads a bare 271 without an envelope around it" do
      source, = x12_answering(described_class, answering(covered_271_for("MEM123", payer_code: "OPT01")),
                              receiver_id: "OPTUM", application_receiver: "OPTUM")

      expect(source.eligibility(inquiry).state).to eq(:complete)
    end

    it "reads a payer that could not answer as the payer being silent" do
      silent = x12_271("ST*271*0001*005010X279A1~", "HL*1**20*1~",
                       "NM1*PR*2*EXAMPLE*****PI*OPT01~", "AAA*Y**42*P~", "SE*5*0001~")
      source, = x12_answering(described_class, answering(silent),
                              receiver_id: "OPTUM", application_receiver: "OPTUM")

      expect(source.eligibility(inquiry).state).to eq(:payer_silent)
    end

    it "reads a bare 999 as a rejection of the transmission" do
      source, = x12_answering(described_class, answering(functional_acknowledgement),
                              receiver_id: "OPTUM", application_receiver: "OPTUM")

      expect(source.eligibility(inquiry).state).to eq(:rejected)
    end
  end

  # Some payers want a tax id in 2100B as well as the NPI; it goes on the Provider.
  describe "a payer that wants more than an NPI in 2100B" do
    it "carries the tax id alongside the NPI" do
      billing = EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC",
                                     tax_id: "123456789")
      asked = inquiry(provider: billing)
      source = described_class.new(credential: optum_credential)

      expect(source.send(:request_body, asked, trace: "T1")).to include("REF*TJ*123456789~")
    end
  end
end
