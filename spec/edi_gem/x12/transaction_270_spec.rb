# frozen_string_literal: true

# The 270 writer, asserted segment by segment against 005010X279A1.
RSpec.describe EdiGem::X12::Transaction270 do
  subject(:transaction) do
    described_class.new(inquiry, payer_code: "38333", payer_name: "EXAMPLE HEALTH PLAN",
                                 trace: "1234567890", now: Time.new(2026, 9, 4, 13, 45, 0))
  end

  let(:subscriber) do
    EdiGem::Subscriber.new(member_id: "MEM123", first_name: "ADA", last_name: "LOVELACE",
                           date_of_birth: "19800101", gender: "F")
  end
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC") }
  let(:inquiry) do
    EdiGem::Inquiry::Eligibility.new(payer_code: "38333",
                                     subscriber: subscriber, provider: provider)
  end

  def segment(id)
    transaction.segments.find { |written| written.start_with?("#{id}*") }
  end

  describe "the transaction header" do
    it "declares the implementation guide it was written to" do
      expect(segment("ST")).to eq("ST*270*0001*005010X279A1~")
    end

    it "identifies itself as an inquiry rather than a response" do
      expect(segment("BHT")).to eq("BHT*0022*13*1234567890*20260904*1345~")
    end
  end

  describe "2100A, the payer being asked" do
    it "carries the payer's code under the payer identification qualifier" do
      expect(segment("NM1")).to eq("NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*38333~")
    end

    it "opens the information source level, which has children" do
      expect(segment("HL")).to eq("HL*1**20*1~")
    end
  end

  describe "2100B, the provider asking" do
    it "asserts our NPI in NM109, which is element nine and not element ten" do
      expect(transaction.segments).to include("NM1*1P*2*EXAMPLECLINIC*****XX*1999999984~")
    end

    it "names a provider who is a person as a person" do
      individual = EdiGem::Provider.new(npi: "1999999984", first_name: "ADA", last_name: "BYRON")
      written = described_class.new(inquiry_for(individual), payer_code: "38333", trace: "1")

      expect(written.segments).to include("NM1*1P*1*BYRON*ADA****XX*1999999984~")
    end

    it "refuses a provider with no name, which NM103 must carry" do
      nameless = EdiGem::Provider.new(npi: "1999999984")
      written = described_class.new(inquiry_for(nameless), payer_code: "38333", trace: "1")

      expect { written.segments }.to raise_error(ArgumentError, /needs a provider name/)
    end

    # NM1 holds one identifier, so a tax id alongside the NPI goes in a REF.
    it "carries a tax id in a REF when the provider has one" do
      billing = EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC",
                                     tax_id: "123456789")
      written = described_class.new(inquiry_for(billing), payer_code: "38333", trace: "1")

      expect(written.segments).to include("REF*TJ*123456789~")
    end

    it "writes no REF at all when the provider has no tax id" do
      expect(transaction.segments).to_not include(a_string_starting_with("REF*TJ"))
    end
  end

  describe "2100C, the member being asked about" do
    it "writes the name in X12's order, which is last then first" do
      expect(transaction.segments).to include("NM1*IL*1*LOVELACE*ADA****MI*MEM123~")
    end

    it "writes a suffix in NM107, apart from the last name, and no title" do
      suffixed = EdiGem::Subscriber.new(member_id: "MEM123", first_name: "Mrs Ada", last_name: "Lovelace III")

      expect(written_for(suffixed).segments).to include("NM1*IL*1*LOVELACE*ADA***III*MI*MEM123~")
    end

    it "carries the birth date and gender the payer matches on" do
      expect(segment("DMG")).to eq("DMG*D8*19800101*F~")
    end

    # A payer that matches on birth date and is handed an empty element answers AAA 71, which
    # reads as a wrong date rather than as none given.
    it "omits DMG rather than sending it empty" do
      nameless = EdiGem::Subscriber.new(member_id: "MEM123", last_name: "LOVELACE")

      expect(written_for(nameless).segments).to_not include(a_string_starting_with("DMG"))
    end

    it "carries an SSN in a REF when the source matches on one" do
      with_ssn = EdiGem::Subscriber.new(last_name: "LOVELACE", ssn: "123456789")

      expect(written_for(with_ssn).segments).to include("REF*SY*123456789~")
    end

    it "asks about general medical benefits, which every payer must answer" do
      expect(segment("EQ")).to eq("EQ*30~")
    end
  end

  describe "the trace number" do
    it "is assigned by us, which is what TRN01 1 means" do
      expect(segment("TRN")).to eq("TRN*1*1234567890*1234567890~")
    end

    # The 271 comes back carrying it, and it is the only way to pair an answer with its question
    # when several are in flight -- which is the whole of how a batch works.
    it "names the originator separately when the caller has been assigned one" do
      written = described_class.new(inquiry, payer_code: "38333", trace: "T1",
                                             originator: "1123456789")

      expect(written.segments).to include("TRN*1*T1*1123456789~")
    end
  end

  describe "the plan date" do
    it "is omitted when the inquiry named none, which is what asks about today" do
      expect(transaction.segments).to_not include(a_string_starting_with("DTP"))
    end

    it "is written as a single date when the inquiry named one" do
      expect(dated("20260820").segments).to include("DTP*291*D8*20260820~")
    end

    # A range takes a different qualifier; RD8 content under D8 is a syntax rejection.
    it "is written under the range qualifier when the inquiry named a range" do
      expect(dated("20260820-20260930").segments)
        .to include("DTP*291*RD8*20260820-20260930~")
    end
  end

  describe "the trailer" do
    it "counts every segment from ST to SE inclusive" do
      expect(transaction.segments.last).to eq("SE*#{transaction.segments.length}*0001~")
    end

    it "repeats the control number the ST opened with" do
      expect(transaction.segments.last).to end_with("*0001~")
    end
  end

  it "writes the whole transaction as one string of segments" do
    expect(transaction.to_s).to start_with("ST*270*0001*005010X279A1~BHT*")
  end

  def inquiry_for(provider)
    EdiGem::Inquiry::Eligibility.new(payer_code: "38333",
                                     subscriber: subscriber, provider: provider)
  end

  def written_for(subscriber, **options)
    inquiry = EdiGem::Inquiry::Eligibility.new(payer_code: "38333",
                                               subscriber: subscriber, provider: provider,
                                               **options)
    described_class.new(inquiry, payer_code: "38333", trace: "1")
  end

  def dated(as_of)
    written_for(subscriber, as_of: as_of)
  end
end

# Office Ally's companion guide prints a complete 270; the writer is checked against it
# element for element.
RSpec.describe "a 270 written the way Office Ally's guide prints one" do
  subject(:written) do
    EdiGem::X12::Transaction270.new(
      inquiry, payer_code: "99999", payer_name: "Blue Shield Somewhere",
               trace: "327636", originator: "9d20314938", submitter_id: "EPIC 965270 265857 PRD",
               control_number: "8307", now: Time.new(2011, 3, 18, 10, 56, 0)
    )
  end

  let(:inquiry) do
    EdiGem::Inquiry::Eligibility.new(
      payer_code: "99999", as_of: "20310318",
      subscriber: EdiGem::Subscriber.new(member_id: "UUE12345678U5", first_name: "FIRST",
                                         last_name: "LAST", date_of_birth: "17560903",
                                         gender: "F"),
      provider: EdiGem::Provider.new(npi: "1166606569",
                                     organization_name: "SOME COMMUNITY HOSPITAL")
    )
  end

  # The guide's example, minus the ISA/GS/GE/IEA that Interchange writes.
  let(:published) do
    <<~X12.lines(chomp: true)
      ST*270*8307*005010X279A1~
      BHT*0022*13*EPIC 965270 265857 PRD*20110318*1056~
      HL*1**20*1~
      NM1*PR*2*Blue Shield Somewhere*****PI*99999~
      HL*2*1*21*1~
      NM1*1P*2*SOME COMMUNITY HOSPITAL*****XX*1166606569~
      HL*3*2*22*0~
      TRN*1*327636*9d20314938~
      NM1*IL*1*LAST*FIRST****MI*UUE12345678U5~
      DMG*D8*17560903*F~
      DTP*291*D8*20310318~
      EQ*30~
      SE*13*8307~
    X12
  end

  it "writes the same transaction the vendor prints" do
    expect(written.segments).to eq(published)
  end

  it "counts the same thirteen segments the vendor's SE01 does" do
    expect(written.segments.last).to eq("SE*13*8307~")
  end
end
