# frozen_string_literal: true

RSpec.describe EdiGem::Codec do
  describe ".decode" do
    it "maps every EB01 that means covered onto one status" do
      expect(%w[1 2 3 4 5].map { |c| described_class.decode(:eb01_status, c) }).to all(eq(:active))
    end

    # The defect the pair exists to close: a co-payment line is not a statement about coverage,
    # and reading every EB01 as a status made one look like one.
    it "gives a benefit line no status" do
      expect(%w[A B C D L U].map { |c| described_class.decode(:eb01_status, c) }).to all(be_nil)
    end

    it "gives an eligibility line no benefit type" do
      expect(%w[1 6 I V].map { |c| described_class.decode(:eb01_benefit, c) }).to all(be_nil)
    end

    it "names the benefit a line describes" do
      expect(described_class.decode(:eb01_benefit, "B")).to eq(:co_payment)
    end

    # Between the two tables every value stays visible. A code neither names is still a benefit
    # line rather than a status, which is the safe side to be wrong on.
    it "keeps an EB01 neither table names as its bare self on the benefit side" do
      expect(described_class.decode(:eb01_benefit, "ZZ")).to eq("ZZ")
    end

    # The lane already says a provider-level refusal is ours, but the code says which of ours,
    # and every one of these means our standing with the payer rather than the member's details.
    it "names the provider-standing refusals rather than leaving them as bare codes" do
      decoded = %w[44 46 47 49 52 53].map { |code| described_class.decode(:aaa03, code) }

      expect(decoded).to all(be_a(Symbol))
    end

    it "keeps an unknown value rather than dropping it" do
      expect(described_class.decode(:aaa03, "99")).to eq("99")
    end

    it "reads where a range of dates starts" do
      expect(described_class.decode(:rd8_start, "20260820-20260930")).to eq("20260820")
    end

    it "reads a single date as where its period starts" do
      expect(described_class.decode(:rd8_start, "20260826")).to eq("20260826")
    end

    it "reads where a range of dates ends" do
      expect(described_class.decode(:rd8_end, "20260820-20260930")).to eq("20260930")
    end

    it "reads no end off a single date" do
      expect(described_class.decode(:rd8_end, "20260826")).to be_nil
    end

    describe "the primary payer a benefit line names" do
      let(:primary) do
        { "entityIdentifier" => "Primary Payer", "entityName" => "UNITEDHEALTHCARE",
          "entityIdentification" => "PI", "entityIdentificationValue" => "87726" }
      end

      let(:care_provider) { { "entityIdentifier" => "Primary Care Provider", "entityName" => "CLINIC" } }

      it "reads its payer code out of the list" do
        expect(described_class.decode(:primary_payer_code, [care_provider, primary])).to eq("87726")
      end

      it "reads its name out of the list" do
        expect(described_class.decode(:primary_payer_name, [care_provider, primary])).to eq("UNITEDHEALTHCARE")
      end

      it "reads a lone entity sent where a list was expected" do
        expect(described_class.decode(:primary_payer_code, primary)).to eq("87726")
      end

      it "reads no payer code off an identifier that is not a payer code" do
        naic = primary.merge("entityIdentification" => "NI")

        expect(described_class.decode(:primary_payer_code, [naic])).to be_nil
      end

      it "reads nothing WHEN no primary payer is named" do
        expect(described_class.decode(:primary_payer_code, [care_provider, "junk"])).to be_nil
      end

      it "reads no name WHEN no primary payer is named" do
        expect(described_class.decode(:primary_payer_name, nil)).to be_nil
      end
    end

    it "returns the value untouched when no codec is named" do
      expect(described_class.decode(nil, "raw")).to eq("raw")
    end

    it "raises for a codec that is not registered" do
      expect { described_class.decode(:nonsense, "1") }.to raise_error(ArgumentError, /nonsense/)
    end
  end
end
