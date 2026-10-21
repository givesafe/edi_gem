# frozen_string_literal: true

# An unimplemented feature raises rather than returning nil, which would read as no coverage.
RSpec.describe EdiGem::Source::Base do
  subject(:port) { described_class.new }

  let(:inquiry) do
    EdiGem::Inquiry::Eligibility.new(
      payer_code: "12345",
      subscriber: EdiGem::Subscriber.new(member_id: "X", last_name: "Y"),
      provider: EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic")
    )
  end

  it "refuses to state its search options" do
    expect { port.search_options }.to raise_error(NotImplementedError)
  end

  it "claims no capability until a source declares one" do
    expect(port.capabilities).to eq(eligibility: false, discovery: false, batch: false)
  end

  it "requires no payer credential" do
    expect(port.required_credentials("12345")).to eq([])
  end

  it "supports nothing" do
    expect(described_class::FEATURES.map { |feature| port.supports?(feature) }).to all(be(false))
  end

  it "accepts a feature named as a string" do
    expect(port.supports?("batch")).to be(false)
  end

  it "refuses to answer for a feature it does not know" do
    expect { port.supports?(:claims) }.to raise_error(ArgumentError, /eligibility, discovery, batch/)
  end

  it "refuses an eligibility check" do
    expect { port.eligibility(inquiry) }
      .to raise_error(EdiGem::FeatureNotSupported, /does not support eligibility/)
  end

  it "refuses a discovery" do
    expect { port.discovery(inquiry) }.to raise_error(EdiGem::FeatureNotSupported, /discovery/)
  end

  it "refuses to resolve a handle" do
    expect { port.resolve("handle") }.to raise_error(EdiGem::FeatureNotSupported, /discovery/)
  end

  it "refuses a batch" do
    expect { port.submit_batch([inquiry], name: "run") }
      .to raise_error(EdiGem::FeatureNotSupported, /batch/)
  end

  it "refuses a batch status" do
    expect { port.batch_status("b1") }.to raise_error(EdiGem::FeatureNotSupported, /batch/)
  end

  it "refuses a page of batch checks" do
    expect { port.batch_checks("b1", page_token: "t") }
      .to raise_error(EdiGem::FeatureNotSupported, /batch/)
  end

  it "is a gem error, so a caller rescuing EdiGem::Error catches it" do
    expect(EdiGem::FeatureNotSupported.ancestors).to include(EdiGem::Error)
  end
end
