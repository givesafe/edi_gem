# frozen_string_literal: true

# A source is chosen by name, so adding a clearinghouse is a change to this gem alone.
RSpec.describe EdiGem::Source, ".for" do
  it "builds the Stedi source from its name and configuration" do
    expect(described_class.for(:stedi, api_key: "test_key", archive: nil))
      .to be_a(EdiGem::Source::Stedi)
  end

  it "hands the configuration to the source it builds" do
    transport = CannedSource::Transport.new([canned("stedi_271_active_coverage")])
    source = described_class.for(:stedi, api_key: "test_key", transport: transport, archive: nil)
    inquiry = EdiGem::Inquiry::Eligibility.new(
      payer_code: "11111", subscriber: EdiGem::Subscriber.new(member_id: "MOCK00000001", last_name: "Testlast"),
      provider: EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic")
    )
    source.eligibility(inquiry)

    expect(transport.paths.size).to eq(1)
  end

  it "builds an X12 source" do
    expect(described_class.for(:optum, credential: enrolled(:optum)))
      .to be_a(EdiGem::Source::Optum)
  end

  it "accepts the name as a string" do
    expect(described_class.for("office_ally", credential: enrolled(:office_ally)))
      .to be_a(EdiGem::Source::OfficeAlly)
  end

  it "lists the names it accepts" do
    expect(described_class.names).to eq(%i[stedi office_ally optum mock])
  end

  it "keys every source by the NAME the source itself declares" do
    declared = described_class::CLASSES.values.map { |klass| described_class.const_get(klass)::NAME }

    expect(declared).to eq(described_class.names)
  end

  it "raises for a name nothing is registered under, and lists the ones that are" do
    expect { described_class.for(:availity) }
      .to raise_error(EdiGem::UnknownSource, /availity.*stedi, office_ally, optum, mock/)
  end

  it "does not take a missing name for a source" do
    expect { described_class.for(nil) }.to raise_error(EdiGem::UnknownSource)
  end

  it "lets the source refuse configuration it does not take" do
    expect { described_class.for(:stedi, api_token: "x") }.to raise_error(ArgumentError)
  end

  it "is a gem error, so a caller rescuing EdiGem::Error catches it" do
    expect(EdiGem::UnknownSource.ancestors).to include(EdiGem::Error)
  end
end
