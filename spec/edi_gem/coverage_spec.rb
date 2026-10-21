# frozen_string_literal: true

require "spec_helper"

RSpec.describe EdiGem::Coverage do
  let(:day) { Date.new(2026, 10, 21) }

  def benefits(lines, plan_dates: {}, schema: :stedi)
    body = { "planDateInformation" => plan_dates, "benefitsInformation" => lines }
    body = { "items" => [body] } if schema == :stedi_discovery
    EdiGem::Reading.new(document: EdiGem::Document::Json.new(body), schema: EdiGem::Schema.fetch(schema)).benefits
  end

  def finding(lines, **options)
    described_class.on(benefits(lines, **options), day).to_h
  end

  %i[stedi stedi_discovery].each do |schema|
    context "WHEN read with #{schema}" do
      it "finds the plan active, with its code, WHEN a line on 30 says so within the plan's dates" do
        lines = [{ "code" => "1", "serviceTypeCodes" => ["30"] }]

        expect(finding(lines, plan_dates: { "plan" => "20260101-20261231" }, schema: schema))
          .to eq(status: :active, code: "1")
      end

      it "finds the plan inactive WHEN the day is past the earliest of the plan's ends" do
        lines = [{ "code" => "1", "serviceTypeCodes" => ["30"] }]
        dates = { "plan" => "20260101-20261231", "eligibilityEnd" => "20260930" }

        expect(finding(lines, plan_dates: dates, schema: schema)).to eq(status: :inactive, code: nil)
      end

      it "finds the plan inactive WHEN the day is before the plan begins" do
        lines = [{ "code" => "1", "serviceTypeCodes" => ["30"] }]

        expect(finding(lines, plan_dates: { "planBegin" => "20261101" }, schema: schema))
          .to eq(status: :inactive, code: nil)
      end

      it "lets a line's own dates win over the plan's for that line" do
        lines = [{ "code" => "1", "serviceTypeCodes" => ["30"],
                   "benefitsDateInformation" => { "benefitBegin" => "20261001", "benefitEnd" => "20261231" } }]

        expect(finding(lines, plan_dates: { "planEnd" => "20260930" }, schema: schema))
          .to eq(status: :active, code: "1")
      end

      it "keeps the plan's end for a line that sends only its own begin" do
        lines = [{ "code" => "1", "serviceTypeCodes" => ["30"],
                   "benefitsDateInformation" => { "benefitBegin" => "20260101" } }]

        expect(finding(lines, plan_dates: { "planEnd" => "20260930" }, schema: schema)[:status]).to eq(:inactive)
      end
    end
  end

  describe "the line that decides" do
    it "reads an inactive line on 30 as inactive, with its code" do
      expect(finding([{ "code" => "7", "serviceTypeCodes" => ["30"] }])).to eq(status: :inactive, code: "7")
    end

    it "reads active over inactive WHEN both are on 30" do
      lines = [{ "code" => "6", "serviceTypeCodes" => ["30"] }, { "code" => "5", "serviceTypeCodes" => ["30"] }]

      expect(finding(lines)).to eq(status: :active, code: "5")
    end

    it "names the plain active code over active pending investigation WHEN the payer sends both" do
      lines = [{ "code" => "5", "serviceTypeCodes" => ["30"] }, { "code" => "1", "serviceTypeCodes" => ["30"] }]

      expect(finding(lines)[:code]).to eq("1")
    end

    it "reads a line that names no service type as about the plan" do
      expect(finding([{ "code" => "1" }])).to eq(status: :active, code: "1")
    end

    it "leaves the plan undecided WHEN only other service types say active" do
      expect(finding([{ "code" => "1", "serviceTypeCodes" => ["35"] }])).to eq(status: nil, code: nil)
    end

    it "reads a plan term on 30 as implied active coverage" do
      expect(finding([{ "code" => "B", "serviceTypeCodes" => ["30"] }])).to eq(status: :active, code: nil)
    end

    it "does not read a plan term that names no service type as implying coverage" do
      expect(finding([{ "code" => "C" }])).to eq(status: nil, code: nil)
    end

    it "reads an explicit inactive over an implied term" do
      lines = [{ "code" => "C", "serviceTypeCodes" => ["30"] }, { "code" => "6", "serviceTypeCodes" => ["30"] }]

      expect(finding(lines)).to eq(status: :inactive, code: "6")
    end

    %w[R U T W P].each do |code|
      it "does not read EB01 #{code} on 30 as implying coverage" do
        expect(finding([{ "code" => code, "serviceTypeCodes" => ["30"] }])).to eq(status: nil, code: nil)
      end
    end

    it "reads a non-covered line on 30 as non_covered" do
      expect(finding([{ "code" => "I", "serviceTypeCodes" => ["30"] }])).to eq(status: :non_covered, code: "I")
    end

    it "reads the line within its dates over one outside them" do
      ended = { "benefitEnd" => "20260101" }
      lines = [{ "code" => "1", "serviceTypeCodes" => ["30"], "benefitsDateInformation" => ended },
               { "code" => "8", "serviceTypeCodes" => ["30"] }]

      expect(finding(lines)).to eq(status: :inactive, code: "8")
    end
  end

  it "reads a day given as X12's YYYYMMDD" do
    lines = benefits([{ "code" => "1", "serviceTypeCodes" => ["30"] }], plan_dates: { "planEnd" => "20261231" })

    expect(described_class.on(lines, "20270101").status).to eq(:inactive)
  end

  it "is what Response#coverage_on answers" do
    response = EdiGem::Response.new(benefits: benefits([{ "code" => "1", "serviceTypeCodes" => ["30"] }]))

    expect(response.coverage_on(day)).to be_active
  end
end
