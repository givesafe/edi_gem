# frozen_string_literal: true

RSpec.describe EdiGem::Document::Json do
  subject(:document) { described_class.new(body) }

  let(:body) do
    { "benefitsInformation" => [{ "code" => "1", "planCoverage" => "Example Medicaid" },
                                { "code" => "6", "planCoverage" => "Dental" }],
      "subscriber" => { "aaaErrors" => [{ "code" => "72" }], "memberId" => "MEM123" } }
  end

  describe "#records" do
    it "fans out over an array address" do
      expect(document.records("benefitsInformation[]").length).to eq(2)
    end

    it "walks into a nested object before fanning out" do
      expect(document.records("subscriber.aaaErrors[]").first.value("code")).to eq("72")
    end

    it "returns one record for a non-array address" do
      expect(document.records("subscriber").first.value("memberId")).to eq("MEM123")
    end

    it "returns an empty list for an address that is not present" do
      expect(document.records("dependents[]")).to be_empty
    end
  end

  describe "#locate" do
    it "positions a record by the array steps taken to reach it, each as its key and index" do
      expect(document.locate("benefitsInformation[]").map(&:first))
        .to eq([[["benefitsInformation", 0]], [["benefitsInformation", 1]]])
    end

    it "gives a record reached through no array an empty position" do
      expect(document.locate("subscriber").map(&:first)).to eq([[]])
    end

    # Two arrays side by side both start at 0, so a position holding only the number would say
    # they were the same place and a reading would fold one plan's benefits into another's.
    it "tells two arrays at the same level apart by their key" do
      document = described_class.new('{"items": [{"a": [{}], "b": [{}]}]}')

      expect([document.locate("items[].a[]"), document.locate("items[].b[]")].map { |at| at.first.first })
        .to eq([[["items", 0], ["a", 0]], [["items", 0], ["b", 0]]])
    end

    it "positions a lone object sent where a list was expected as the first of that list" do
      document = described_class.new('{"benefitsInformation": {"code": "1"}}')

      expect(document.locate("benefitsInformation[]").map(&:first)).to eq([[["benefitsInformation", 0]]])
    end
  end

  it "accepts a JSON string as readily as a parsed hash" do
    expect(described_class.new(JSON.generate(body)).records("benefitsInformation[]").length).to eq(2)
  end

  # A path step that lands on something that is not an object -- a string, a number, nil.
  # There is nothing under it, so it contributes no records rather than raising.
  it "finds nothing under a step that is not an object" do
    document = described_class.new('{"planStatus": "active"}')

    expect(document.records("planStatus.serviceTypeCodes")).to be_empty
  end

  describe "a body that is not JSON" do
    let(:body) { "<html>MEM123 upstream error</html>" }

    it "raises the gem's own error, which a caller rescuing the gem records" do
      expect { document }.to raise_error(EdiGem::UnreadableBody)
    end

    it "names no part of the body, which is a member's" do
      expect { document }.to(raise_error { |error| expect(error.message).to_not include("MEM123") })
    end
  end
end
