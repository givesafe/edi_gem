# frozen_string_literal: true

RSpec.describe EdiGem::Inquiry::Eligibility do
  let(:provider) { EdiGem::Provider.new(npi: "1234567890", organization_name: "Example Clinic") }
  let(:subscriber) do
    EdiGem::Subscriber.new(member_id: "MEM123", first_name: "Ada", last_name: "Lovelace",
                           date_of_birth: "19151210")
  end

  subject(:inquiry) do
    described_class.new(payer_code: "12345", subscriber: subscriber, provider: provider)
  end

  it "asks about plan coverage unless told otherwise" do
    expect(inquiry.service_type_codes).to eq(["30"])
  end

  it "carries the payer code it was given" do
    expect(inquiry.payer_code).to eq("12345")
  end

  it "carries no payer name unless given one" do
    expect(inquiry.payer_name).to be_nil
  end

  it "carries the payer name it was given" do
    named = described_class.new(payer_code: "12345", payer_name: "EXAMPLE HEALTH PLAN",
                                subscriber: subscriber, provider: provider)

    expect(named.payer_name).to eq("EXAMPLE HEALTH PLAN")
  end

  it "requires no credentials unless told otherwise" do
    expect(inquiry.required_credentials).to eq([])
  end

  it "holds the required credentials as symbols" do
    needing = described_class.new(payer_code: "12345", required_credentials: ["portal_password"],
                                  subscriber: subscriber, provider: provider)

    expect(needing.required_credentials).to eq([:portal_password])
  end

  it "refuses to be built without a payer code" do
    expect { described_class.new(subscriber: subscriber, provider: provider) }
      .to raise_error(ArgumentError, /payer_code/)
  end

  describe "#satisfies?" do
    it "accepts a combination the subscriber can fill" do
      expect(inquiry.satisfies?([%i[member_id last_name date_of_birth]])).to be(true)
    end

    it "rejects one it cannot" do
      expect(inquiry.satisfies?([%i[member_id ssn]])).to be(false)
    end

    it "accepts when any one of several combinations is filled" do
      expect(inquiry.satisfies?([%i[ssn], %i[member_id last_name]])).to be(true)
    end
  end
end

# "Today" depends on the caller's time zone, so a discovery must be given its date.
RSpec.describe EdiGem::Inquiry::Discovery do
  let(:subscriber) { EdiGem::Subscriber.new(first_name: "A", last_name: "B") }
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic") }

  it "refuses to be built without a date to ask about" do
    expect { described_class.new(subscriber: subscriber, provider: provider) }
      .to raise_error(ArgumentError, /as_of/)
  end

  it "refuses a nil date too, which a required keyword alone would accept" do
    expect { described_class.new(subscriber: subscriber, provider: provider, as_of: nil) }
      .to raise_error(ArgumentError, /as_of/)
  end

  it "takes the date it is given" do
    inquiry = described_class.new(subscriber: subscriber, provider: provider, as_of: "20260901")

    expect(inquiry.service_date).to eq("20260901")
  end
end

RSpec.describe "EdiGem::Inquiry::Eligibility#service_date" do
  subject(:inquiry) do
    EdiGem::Inquiry::Eligibility.new(
      payer_code: "12345",
      subscriber: EdiGem::Subscriber.new(member_id: "X", last_name: "Y"),
      provider: EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic"),
      as_of: as_of
    )
  end

  context "WHEN the inquiry named no date" do
    let(:as_of) { nil }

    it "is nil when the source offered no default" do
      expect(inquiry.service_date).to be_nil
    end

    it "takes the source's default when it has one" do
      expect(inquiry.service_date(default: Date.new(2026, 9, 4))).to eq("20260904")
    end
  end

  context "WHEN the inquiry named a date" do
    let(:as_of) { Date.new(2026, 8, 20) }

    it "writes it as X12 YYYYMMDD rather than ISO" do
      expect(inquiry.service_date).to eq("20260820")
    end

    it "ignores the source's default" do
      expect(inquiry.service_date(default: Date.new(2026, 9, 4))).to eq("20260820")
    end
  end

  # A range is a legal X12 date and not a Ruby one, so it passes through as written.
  context "WHEN the date is already written the way the payer wants it" do
    let(:as_of) { "20260820-20260930" }

    it "passes it through untouched" do
      expect(inquiry.service_date).to eq("20260820-20260930")
    end
  end
end
