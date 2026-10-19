# frozen_string_literal: true

# The README promises that the objects carrying PHI and secrets refuse to print their contents.
# Until now nothing checked it: three of these #inspect methods had never been executed by the
# suite at all, which is how a promise like this quietly stops being true.
#
# What each must do is print its field NAMES and never a value, because inspect output is what
# ends up in an exception, a log line and a session transcript.
RSpec.describe "objects that refuse to print their contents" do
  describe EdiGem::Subscriber do
    subject(:printed) do
      described_class.new(member_id: "9AB12345678", first_name: "Jane", last_name: "Doe",
                          date_of_birth: "19570304").inspect
    end

    it "names the fields it holds" do
      expect(printed).to include("memberId", "firstName", "lastName")
    end

    it "prints no name" do
      expect(printed).to_not include("Jane", "Doe")
    end

    it "prints no member id" do
      expect(printed).to_not include("9AB12345678")
    end

    it "prints no date of birth" do
      expect(printed).to_not include("19570304")
    end
  end

  describe EdiGem::Benefit do
    subject(:printed) { described_class.new(member_id: "9AB12345678", plan_name: "GOLD").inspect }

    it "names the attributes it holds" do
      expect(printed).to include("member_id", "plan_name")
    end

    it "prints no value" do
      expect(printed).to_not include("9AB12345678", "GOLD")
    end
  end

  describe EdiGem::Payload do
    subject(:printed) do
      described_class.new(body: '{"subscriber":{"memberId":"9AB12345678"}}', dialect: :json).inspect
    end

    it "reports the dialect and the size, which is what a log line legitimately wants" do
      expect(printed).to match(/json 41 bytes/)
    end

    it "prints none of the body" do
      expect(printed).to_not include("9AB12345678")
    end
  end

  describe EdiGem::Credential do
    let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic") }

    let(:printed) do
      described_class.new(provider: provider, source: :stedi,
                          values: { portal_password: "4821" }).inspect
    end

    it "names the values it holds" do
      expect(printed).to include("portal_password")
    end

    it "prints no secret" do
      expect(printed).to_not include("4821")
    end

    # Credential.none carries no provider, and reading an npi off nil is the branch that had
    # never run -- an error inside inspect surfaces at the worst possible moment.
    it "prints without a provider" do
      expect(described_class.none.inspect).to be_a(String)
    end
  end

  describe EdiGem::Exchange do
    subject(:printed) do
      described_class.new(method: :post, url: "https://example.test/eligibility", status: 200,
                          request_body: '{"memberId":"9AB12345678"}',
                          response_body: '{"subscriber":{"firstName":"Jane"}}').inspect
    end

    it "reports the call, which is what identifies it in a log" do
      expect(printed).to include("POST", "https://example.test/eligibility", "200")
    end

    it "prints neither body" do
      expect(printed).to_not include("9AB12345678", "Jane")
    end
  end
end
