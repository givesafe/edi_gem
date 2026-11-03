# frozen_string_literal: true

# Every AAA03 code in the vendor's published enum is accounted for, so no code falls through
# the state machine unread.
RSpec.describe "AAA03 reject reasons, against Stedi's published enum" do
  let(:published) do
    JSON.parse(File.read(File.join(CannedSource::FIXTURES, "stedi_aaa03_codes.json")))
  end
  let(:every_code) { published["any"] }
  let(:named) { EdiGem::Codec::REJECT_REASON.keys }
  let(:unnamed) { EdiGem::Codec::UNNAMED_REASONS }

  it "accounts for every code the vendor publishes, as named or as explicitly unnamed" do
    expect(every_code - named - unnamed).to be_empty
  end

  it "claims no code the vendor does not publish" do
    expect(named + unnamed - every_code).to be_empty
  end

  it "does not both name and disclaim the same code" do
    expect(named & unnamed).to be_empty
  end

  # The per-level lists are subsets of the top level, which Stedi describes as a superset
  # because it bubbles every error up. If that stops being true, a level's codes are arriving
  # somewhere we do not read.
  %w[payer provider subscriber dependent].each do |level|
    it "sees every #{level}-level code in the top-level list too" do
      expect(published[level] - every_code).to be_empty
    end
  end

  describe "a code we have named" do
    subject(:rejection) do
      EdiGem::Rejection.new(level: :payer, code: EdiGem::Codec.decode(:aaa03, "42"))
    end

    it "decodes to a name rather than the wire value" do
      expect(rejection.code).to eq(:payer_unavailable)
    end

    it "can be retryable" do
      expect(rejection).to be_retryable
    end
  end

  describe "a code the vendor publishes and we have not named" do
    subject(:rejection) do
      EdiGem::Rejection.new(level: :subscriber, code: EdiGem::Codec.decode(:aaa03, "AA"),
                            followup: "Resubmission Allowed")
    end

    it "keeps the wire value, because inventing a meaning is the expensive kind of wrong" do
      expect(rejection.code).to eq("AA")
    end

    # The follow-up says a resubmission is allowed, and we still refuse to call it retryable:
    # we do not know what the code means, so a retry is a guess that costs a billed check.
    it "is not retryable even when the follow-up invites a retry" do
      expect(rejection).to_not be_retryable
    end
  end

  describe "the dependent lane" do
    it "is a level, because the vendor publishes a dependent code set" do
      expect(EdiGem::Rejection::LEVELS).to include(:dependent)
    end

    it "is recovered from a 2100D loop in a flattened error list" do
      expect(EdiGem::Rejection.level_from("Loop 2100D")).to eq(:dependent)
    end

    it "is recovered from a 2000D loop as well" do
      expect(EdiGem::Rejection.level_from("Loop 2000D")).to eq(:dependent)
    end
  end
end
