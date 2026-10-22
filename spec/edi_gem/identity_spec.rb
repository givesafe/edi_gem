# frozen_string_literal: true

# Whether the person a payer answered about is the one asked about. Payers spell names their own
# way, and only CORE-certified ones normalize as CAQH CORE 258 says, so a spelling difference
# passes and another name does not.
RSpec.describe EdiGem::Identity do
  let(:asked) { { first_name: "José", last_name: "García-López", date_of_birth: "20100101" } }

  def compare(corrected: false, **returned)
    described_class.compare(asked: asked, returned: returned, corrected: corrected)
  end

  def fields(**returned) = compare(**returned).fields

  describe ".plain, a name as sent" do
    it "spells accents out and uppercases, keeping punctuation a payer may hold" do
      expect(described_class.plain(" José  García-López ")).to eq("JOSE GARCIA-LOPEZ")
    end

    it "spells letters with no decomposed form as payers write them" do
      expect(described_class.plain("Strauß Ørsted")).to eq("STRAUSS ORSTED")
    end

    it "turns a backtick into an apostrophe, as Stedi does" do
      expect(described_class.plain("O`Brien")).to eq("O'BRIEN")
    end

    it "leaves nothing as nothing" do
      expect(described_class.plain(nil)).to be_nil
    end
  end

  describe "a spelling difference" do
    it "matches without accents, in capitals, with a space for the hyphen" do
      expect(compare(first_name: "JOSE", last_name: "GARCIA LOPEZ", date_of_birth: "20100101"))
        .to be_matched
    end

    it "matches with the hyphen dropped and the words run together" do
      expect(fields(first_name: "JOSE", last_name: "GARCIALOPEZ")[:last_name]).to eq(:matched)
    end

    it "matches one of the two last names" do
      expect(fields(first_name: "JOSE", last_name: "GARCIA")[:last_name]).to eq(:matched)
    end

    it "matches a last name with a suffix the payer dropped" do
      suffixed = { first_name: "Leo", last_name: "Smith Jr.", date_of_birth: "20100101" }
      result = described_class.compare(asked: suffixed, returned: { last_name: "SMITH" })

      expect(result.fields[:last_name]).to eq(:matched)
    end

    it "keeps a suffix-only last name rather than comparing nothing" do
      result = described_class.compare(asked: { last_name: "V" }, returned: { last_name: "V" })

      expect(result.fields[:last_name]).to eq(:matched)
    end

    it "matches a first name with a second name the payer left off" do
      result = described_class.compare(asked: { first_name: "Mary Ann" },
                                       returned: { first_name: "MARY" })

      expect(result.fields[:first_name]).to eq(:matched)
    end

    it "matches a long name the payer cut short" do
      long = { first_name: "Christopherson", last_name: "Vanderbiltington" }
      result = described_class.compare(asked: long,
                                       returned: { first_name: "CHRISTOP", last_name: "VANDERBI" })

      expect(result.fields.values_at(:first_name, :last_name)).to eq(%i[matched matched])
    end

    it "matches a birth date written with hyphens or as a date" do
      expect(fields(date_of_birth: Date.new(2010, 1, 1))[:date_of_birth]).to eq(:matched)
      expect(fields(date_of_birth: "2010-01-01")[:date_of_birth]).to eq(:matched)
    end
  end

  describe "another person" do
    it "differs on a one-letter difference, which is how twins differ" do
      leo = { first_name: "Leo", last_name: "Smith", date_of_birth: "20100101" }
      result = described_class.compare(asked: leo, returned: { first_name: "LEON",
                                                               last_name: "SMITH",
                                                               date_of_birth: "20100101" })

      expect(result).to be_mismatched
      expect(result.differing).to eq([:first_name])
    end

    it "differs on a short prefix, which is too likely another name" do
      result = described_class.compare(asked: { first_name: "Leonard" },
                                       returned: { first_name: "LEO" })

      expect(result.fields[:first_name]).to eq(:differs)
    end

    it "differs when the asked name is the shorter one" do
      result = described_class.compare(asked: { first_name: "Christop" },
                                       returned: { first_name: "CHRISTOPHERSON" })

      expect(result.fields[:first_name]).to eq(:differs)
    end

    it "differs on two first names that only start alike" do
      result = described_class.compare(asked: { first_name: "Mary Ann" },
                                       returned: { first_name: "MARY BETH" })

      expect(result.fields[:first_name]).to eq(:differs)
    end

    it "differs on a nickname" do
      result = described_class.compare(asked: { first_name: "William" },
                                       returned: { first_name: "BILL" })

      expect(result.fields[:first_name]).to eq(:differs)
    end

    it "differs on a birth date a day out" do
      expect(fields(date_of_birth: "20100102")[:date_of_birth]).to eq(:differs)
    end

    it "differs on a name with no letters in it" do
      expect(fields(first_name: "--")[:first_name]).to eq(:differs)
      expect(fields(last_name: "--")[:last_name]).to eq(:differs)
    end

    it "does not take a cut-short name when told not to" do
      long = { first_name: "Christopherson" }
      result = described_class.compare(asked: long, returned: { first_name: "CHRISTOP" },
                                       truncated: false)

      expect(result.fields[:first_name]).to eq(:differs)
    end
  end

  describe "nothing to compare" do
    it "is not_compared when the payer sent no birth date and nothing differs" do
      result = compare(first_name: "JOSE", last_name: "GARCIA LOPEZ")

      expect(result.outcome).to eq(:not_compared)
      expect(result.fields[:date_of_birth]).to eq(:not_returned)
    end

    it "is mismatched when a name differs, even with no birth date to compare" do
      expect(compare(first_name: "MARIA", last_name: "GARCIA LOPEZ").outcome).to eq(:mismatched)
    end
  end

  describe "a payer that says it corrected the identity (001/25)" do
    it "takes its spelling of the names when the birth date matches" do
      result = compare(first_name: "JOSEPH", last_name: "GARCIA", date_of_birth: "20100101",
                       corrected: true)

      expect(result).to be_matched
      expect(result.corrected).to eq([:first_name])
    end

    it "never relaxes the birth date" do
      result = compare(first_name: "JOSEPH", last_name: "GARCIA", date_of_birth: "20100102",
                       corrected: true)

      expect(result).to be_mismatched
      expect(result.corrected).to eq([])
    end

    it "corrects nothing when the names already match" do
      result = compare(first_name: "JOSE", last_name: "GARCIA", date_of_birth: "20100101",
                       corrected: true)

      expect(result.corrected).to eq([])
    end
  end
end
