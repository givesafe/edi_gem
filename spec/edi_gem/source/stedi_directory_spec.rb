# frozen_string_literal: true

# Stedi's payer directory, against canned answers shaped as its payer search returns them. The
# payers here are made up.
RSpec.describe "Stedi's payer directory" do
  def listed(code, aliases: [], eligibility: "SUPPORTED", name: "EXAMPLE PAYER")
    { "payer" => { "stediId" => "stedi-#{code}", "primaryPayerId" => code, "displayName" => name,
                   "aliases" => aliases, "operatingStates" => ["ZZ"],
                   "transactionSupport" => { "eligibilityCheck" => eligibility } } }
  end

  def directory(*payers)
    stedi_answering(canned_body({ "items" => payers }))
  end

  describe "#payers" do
    it "reads the payer the directory returns" do
      source, = directory(listed("99999", aliases: ["ALIAS1"], eligibility: "ENROLLMENT_REQUIRED"))
      payer = source.payers("99999").first

      expect([payer.code, payer.clearinghouse_id, payer.aliases, payer.eligibility])
        .to eq(["99999", "stedi-99999", ["ALIAS1"], "ENROLLMENT_REQUIRED"])
    end

    it "sends one request to the policy's payer search path" do
      source, transport = directory(listed("99999"))
      source.payers("99999")

      expect(transport.paths).to eq([EdiGem::Policy.for(:stedi).path_for(:payer_search)])
    end

    it "returns nothing WHEN the directory has no match" do
      source, = directory

      expect(source.payers("00000")).to eq([])
    end

    it "returns nothing WHEN the answer carries no items" do
      source, = stedi_answering(canned_body({}))

      expect(source.payers("00000")).to eq([])
    end
  end

  describe "#payer_id_for" do
    it "returns the payer ID for its own code" do
      source, = directory(listed("99999"))

      expect(source.payer_id_for("99999")).to eq "99999"
    end

    it "returns the payer ID for an alias" do
      source, = directory(listed("99999", aliases: ["ALIAS1"]))

      expect(source.payer_id_for("ALIAS1")).to eq "99999"
    end

    it "returns the payer ID for the clearinghouse's own ID" do
      source, = directory(listed("99999"))

      expect(source.payer_id_for("stedi-99999")).to eq "99999"
    end

    it "does not match a payer by name" do
      source, = directory(listed("99999", name: "EXAMPLE PAYER"))

      expect(source.payer_id_for("EXAMPLE PAYER")).to be_nil
    end

    it "returns nil WHEN the directory has no match" do
      source, = directory

      expect(source.payer_id_for("00000")).to be_nil
    end

    it "returns nil WHEN two payers answer to the code by alias" do
      source, = directory(listed("11111", aliases: ["SHARED"]), listed("22222", aliases: ["SHARED"]))

      expect(source.payer_id_for("SHARED")).to be_nil
    end

    it "prefers the payer whose own code it is over one that lists it as an alias" do
      source, = directory(listed("11111", aliases: ["22222"]), listed("22222"))

      expect(source.payer_id_for("22222")).to eq "22222"
    end

    it "takes a code given as a number" do
      source, = directory(listed("99999"))

      expect(source.payer_id_for(99_999)).to eq "99999"
    end

    it "returns nil without asking for a blank code" do
      source, transport = directory

      expect([source.payer_id_for(" "), source.payer_id_for(nil), transport.paths]).to eq([nil, nil, []])
    end
  end
end
