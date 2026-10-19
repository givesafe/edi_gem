# frozen_string_literal: true

# A 999 in place of the 271. Built from the 005010X231A1 implementation guide rather than taken
# off a wire: no call to a clearinghouse that answers in 999s has ever been made.
RSpec.describe EdiGem::X12::Acknowledgement do
  def rejections(body)
    described_class.new(EdiGem::Document::X12.new(body)).rejections
  end

  describe "#rejections" do
    subject(:refusal) { rejections(functional_acknowledgement).first }

    it "is one refusal in the envelope lane WHEN the transaction was rejected" do
      expect(rejections(functional_acknowledgement).map(&:level)).to eq([:envelope])
    end

    it "carries the reason the transaction was refused" do
      expect(refusal.code).to eq("5")
    end

    it "names the segment the clearinghouse could not accept, in its loop" do
      expect(refusal.location).to eq("2100C/NM1")
    end

    it "is a refusal WHEN only the group verdict says so" do
      expect(rejections(functional_acknowledgement(transaction: "A", group: "W")).length).to eq(1)
    end

    it "is empty WHEN the transmission was accepted with errors noted" do
      expect(rejections(functional_acknowledgement(transaction: "E", group: "E"))).to be_empty
    end

    it "is empty for a 271, which has no verdict in it" do
      expect(rejections(covered_271_for("MEM123"))).to be_empty
    end

    it "names no segment WHEN the 999 names none" do
      bare = x12_271("ST*999*0001*005010X231A1~", "AK1*HS*1*005010X279A1~",
                     "AK9*R*1*1*0~", "SE*4*0001~")

      expect(rejections(bare).first.location).to be_nil
    end
  end
end
