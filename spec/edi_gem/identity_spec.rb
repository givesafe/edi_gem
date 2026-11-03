# frozen_string_literal: true

# The forms of a name the gem and its callers share. Payers spell names their own way, and only
# CORE-certified ones normalize as CAQH CORE 258 says, so a caller compares from these forms.
RSpec.describe EdiGem::Identity do
  describe ".payer_normalized, a name as sent" do
    it "removes accents and uppercases, keeping punctuation a payer may hold" do
      expect(described_class.payer_normalized(" José  García-López ")).to eq("JOSE GARCIA-LOPEZ")
    end

    it "spells letters with no decomposed form as payers write them" do
      expect(described_class.payer_normalized("Strauß Ørsted")).to eq("STRAUSS ORSTED")
    end

    it "turns a backtick into an apostrophe, as Stedi does" do
      expect(described_class.payer_normalized("O`Brien")).to eq("O'BRIEN")
    end

    it "removes the characters Stedi refuses in a request" do
      expect(described_class.payer_normalized("Lo~v*e:l^a>ce")).to eq("LOVELACE")
    end

    it "leaves nothing as nothing" do
      expect(described_class.payer_normalized(nil)).to be_nil
    end
  end

  describe ".payer_sent, a first or middle name as sent" do
    it "sends no title at either end" do
      expect(described_class.payer_sent("Dr. Ada")).to eq("ADA")
      expect(described_class.payer_sent("Ada Mary RN")).to eq("ADA MARY")
    end

    it "keeps a name that is only a title rather than sending none" do
      expect(described_class.payer_sent("Ms")).to eq("MS")
    end

    it "leaves nothing as nothing" do
      expect(described_class.payer_sent(nil)).to be_nil
    end
  end

  describe ".payer_sent_last_name, a last name as sent and its suffix" do
    # Stedi takes a generation suffix in the subscriber's own suffix field, not in lastName.
    it "takes a suffix apart, with or without its period or comma" do
      expect(["Smith Jr.", "Smith, JR", "smith iii"].map { described_class.payer_sent_last_name(_1) })
        .to eq([%w[SMITH JR], %w[SMITH JR], %w[SMITH III]])
    end

    it "is the last name and no suffix WHEN it has none" do
      expect(described_class.payer_sent_last_name("García-López")).to eq(["GARCIA-LOPEZ", nil])
    end

    it "sends no title, and finds the suffix before one" do
      expect(described_class.payer_sent_last_name("Smith Jr MD")).to eq(%w[SMITH JR])
    end

    it "keeps a one-word last name that reads as a suffix" do
      expect(described_class.payer_sent_last_name("V")).to eq(["V", nil])
    end

    it "is nothing for nothing" do
      expect(described_class.payer_sent_last_name(nil)).to eq([nil, nil])
    end
  end

  describe ".suffix, a last name's suffix" do
    it "is the suffix, or nil" do
      expect(["Smith Sr.", "Smith I", "Smith"].map { described_class.suffix(_1) }).to eq(["SR", "I", nil])
    end
  end

  describe ".db_normalized, a name as it says who someone is" do
    it "doesn't count accents, case, spaces, hyphens or apostrophes" do
      names = ["José García-López", "jose garcia lopez", " JOSE  GARCIALOPEZ "]
      expect(names.map { described_class.db_normalized(_1) })
        .to eq %w[JOSEGARCIALOPEZ JOSEGARCIALOPEZ JOSEGARCIALOPEZ]
      expect(described_class.db_normalized("O'Brien")).to eq described_class.db_normalized("OBrien")
    end

    it "counts a suffix, which makes another person" do
      expect(described_class.db_normalized("Gomez Jr")).to_not eq described_class.db_normalized("Gomez")
    end

    it "is nil for a blank name" do
      expect([nil, "", " - "].map { described_class.db_normalized(_1) }).to eq [nil, nil, nil]
    end
  end

  describe ".payer_normalized_split, a name's words" do
    it "is the words as sent, with punctuation a space" do
      expect(described_class.payer_normalized_split("José García-López")).to eq(%w[JOSE GARCIA LOPEZ])
    end

    it "is no words for nothing" do
      expect(described_class.payer_normalized_split(nil)).to eq([])
    end
  end

  describe ".surname_words, a last name's words without suffixes or titles" do
    it "drops a suffix or title" do
      expect(described_class.surname_words("Smith Jr.")).to eq(%w[SMITH])
      expect(described_class.surname_words("Smith PhD")).to eq(%w[SMITH])
    end

    it "keeps a suffix-only last name rather than leaving no words" do
      expect(described_class.surname_words("V")).to eq(%w[V])
    end
  end
end
