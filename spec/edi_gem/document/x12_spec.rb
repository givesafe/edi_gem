# frozen_string_literal: true

RSpec.describe EdiGem::Document::X12 do
  subject(:document) { described_class.new(covered_271) }

  describe "#records" do
    it "finds a segment by id" do
      expect(document.records("EB").length).to eq(1)
    end

    it "reads an element by its usual reference" do
      expect(document.records("EB").first.value("EB01")).to eq("1")
    end

    it "returns an empty list for a segment the transaction does not carry" do
      expect(document.records("AAA")).to be_empty
    end
  end

  describe "loop membership" do
    it "puts a rejection in the loop its HL level opened" do
      rejected = described_class.new(rejected_271)

      expect(rejected.records("2100C/AAA").first.value("AAA03")).to eq("72")
    end

    it "does not find that rejection in another loop" do
      expect(described_class.new(rejected_271).records("2100B/AAA")).to be_empty
    end

    it "reads the payer name out of the information source loop" do
      expect(document.records("2100A/NM1").first.value("NM103")).to eq("EXAMPLE HEALTH PLAN")
    end
  end

  describe "#locate" do
    subject(:document) do
      described_class.new(x12_271("EB*1~", "HL*1**20*1~", "HL*2*1*21*1~", "HL*3*2*22*0~",
                                  "DTP*356*D8*20260101~", "EB*1~", "EB*C~", "AMT*R*20~"))
    end

    let(:subscriber) { [%w[HL 1], %w[HL 2], %w[HL 3]] }

    it "places a segment in the subscriber's level under every level above it" do
      expect(document.locate("DTP").map(&:first)).to eq([subscriber])
    end

    it "places each benefit line apart, after the level it sits in" do
      expect(document.locate("2110C/EB").map(&:first)).to eq([subscriber + [["EB", 0]], subscriber + [["EB", 1]]])
    end

    it "places a segment with the line it follows" do
      expect(document.locate("AMT").map(&:first)).to eq([subscriber + [["EB", 1]]])
    end

    it "places a line that comes before any level at the top" do
      expect(document.locate("EB").first.first).to eq([["EB", 0]])
    end
  end

  describe "delimiters" do
    it "reads them from the ISA rather than assuming them" do
      pipe_delimited = covered_271.tr("*", "|").sub("ISA|", "ISA|")

      expect(described_class.new(pipe_delimited).records("EB").first.value("EB01")).to eq("1")
    end

    it "parses nothing when the body is too short to carry an ISA" do
      expect(described_class.new("EB*1~").records("EB")).to be_empty
    end
  end

  # Two shapes the parser meets in real payloads: a trailing separator, which splits to an empty
  # segment; and a field reference with no element number, which addresses nothing.
  describe "the shapes a real 271 arrives in" do
    subject(:document) { described_class.new(x12_271("EB*1**30~", "~", "SE*3*0001~")) }

    it "skips an empty segment rather than recording one with no id" do
      expect(document.records("EB").size).to eq(1)
    end

    it "answers nil for a field reference carrying no element position" do
      expect(document.one("EB", "EB")).to be_nil
    end
  end
end
