# frozen_string_literal: true

# The envelope, and the round trip through the gem's own reader. The reader takes the
# delimiters from the ISA by byte offset, so every width is asserted.
RSpec.describe EdiGem::X12::Interchange do
  subject(:interchange) do
    described_class.new(sender: "EXAMPLECLINIC", receiver: "OFFALLY", control_number: "1",
                        now: Time.new(2026, 9, 4, 13, 45, 0))
  end

  let(:wrapped) { interchange.wrap(["ST*270*0001*005010X279A1~", "SE*2*0001~"]) }
  let(:isa) { wrapped[0, 106] }

  # ISA elements by their standard numbers, so a spec says ISA06 rather than an offset nobody
  # can check by eye. The offsets the reader actually uses are asserted separately, above.
  def isa_element(number)
    isa.split("*")[number]
  end

  describe "the interchange control header" do
    it "is exactly 106 bytes, which is what the reader indexes into" do
      expect(isa.length).to eq(106)
    end

    it "ends with the segment terminator the reader takes from offset 105" do
      expect(isa[-1]).to eq("~")
    end

    it "carries the element separator the reader takes from offset 3" do
      expect(isa[3]).to eq("*")
    end

    it "carries the component separator the reader takes from offset 104" do
      expect(isa[104]).to eq(":")
    end

    # ISA06 and ISA08 are 15 characters whatever the id is. Office Ally's default receiver is
    # OFFALLY, seven characters, and the eight spaces after it are part of the element.
    it "pads the sender id to its full width" do
      expect(isa_element(6)).to eq("EXAMPLECLINIC  ")
    end

    it "pads the receiver id to its full width" do
      expect(isa_element(8)).to eq("OFFALLY        ")
    end

    # ISA09 is YYMMDD where GS04 in the same envelope is CCYYMMDD. Writing either in the other's
    # format shifts every offset after it, or is a syntax rejection.
    it "writes the interchange date as YYMMDD, which is not the group's format" do
      expect(isa_element(9)).to eq("260904")
    end
  end

  describe "the usage indicator, which decides whether a payer is billed" do
    it "is a test interchange unless the caller says otherwise" do
      expect(isa_element(15)).to eq("T")
    end

    it "reports itself as not production" do
      expect(interchange).to_not be_production
    end

    it "is P only when the caller asked for production" do
      live = described_class.new(sender: "S", receiver: "R", control_number: "1",
                                 usage: described_class::PRODUCTION)

      expect(live).to be_production
    end
  end

  describe "the functional group" do
    it "declares an eligibility inquiry, which comes back as HB" do
      expect(wrapped).to include("GS*HS*EXAMPLECLINIC*OFFALLY*20260904*1345*1*X*005010X279A1~")
    end

    it "counts the transaction sets it carries" do
      expect(wrapped).to include("GE*1*1~")
    end

    it "counts more than one when a batch file carries more" do
      several = interchange.wrap(["ST*270*0001~", "SE*2*0001~"], ["ST*270*0002~", "SE*2*0002~"])

      expect(several).to include("GE*2*1~")
    end
  end

  describe "the interchange trailer" do
    # IEA02 has to repeat ISA13 exactly, and ISA13 is nine digits zero-padded. Repeating the
    # caller's "1" rather than the padded form is a control-number mismatch, which is a TA1
    # rejection of the whole interchange before any payer sees it.
    it "repeats the control number in the form the ISA wrote it" do
      expect(wrapped).to end_with("IEA*1*000000001~")
    end

    it "writes the same control number in both places" do
      expect(isa_element(13)).to eq("000000001")
    end
  end

  # What the gem writes, its own reader reads.
  describe "a 270 written and then read back" do
    subject(:document) { EdiGem::Document::X12.new(interchange.wrap(transaction.segments)) }

    let(:transaction) do
      EdiGem::X12::Transaction270.new(
        EdiGem::Inquiry::Eligibility.new(
          payer_code: "38333",
          subscriber: EdiGem::Subscriber.new(member_id: "MEM123", last_name: "LOVELACE"),
          provider: EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC")
        ), payer_code: "38333", trace: "1234567890"
      )
    end

    it "parses into segments rather than into nothing" do
      expect(document.segments).to_not be_empty
    end

    it "finds the payer where a 271 reader looks for it" do
      expect(document.one("2100A/NM1[PR]", "NM109")).to eq("38333")
    end

    it "finds the member where a 271 reader looks for them" do
      expect(document.one("2100C/NM1[IL]", "NM109")).to eq("MEM123")
    end

    it "puts the provider in the receiver level and not the subscriber's" do
      expect(document.records("2100C/NM1[1P]")).to be_empty
    end
  end

  describe "an identifier longer than its element" do
    subject(:interchange) do
      described_class.new(sender: "A" * 20, receiver: "R", control_number: "1")
    end

    # Truncating loses an identifier and the vendor refuses the interchange, which is visible.
    # Overflowing shifts every offset after it and makes the whole thing unreadable, which is
    # not -- so this fails in the direction someone will notice.
    it "truncates rather than shifting every offset after it" do
      expect(isa.length).to eq(106)
    end
  end
end
