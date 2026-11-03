# frozen_string_literal: true

RSpec.describe EdiGem::Rejection do
  def rejection(**attrs) = described_class.new(level: :subscriber, **attrs)

  # Stedi's troubleshooting guide: ask a payer that can't answer right now again at once (42, 80),
  # but not a 42 whose follow-up is C, N or S, which says the request itself has a problem.
  describe "#retryable?" do
    def down(reason_code, followup)
      rejection(level: :payer, code: :payer_unavailable,
                reason_code: reason_code, followup: followup)
    end

    it "retries a 42 whose follow-up allows it, or that has none" do
      expect([down("42", "Please Resubmit Original Transaction"), down("42", "R"), down("42", nil)])
        .to all(be_retryable)
    end

    it "does not retry a 42 whose follow-up is C, N or S, as words or as the letter" do
      followups = ["Please Correct and Resubmit", "Resubmission Not Allowed",
                   "Do Not Resubmit; Inquiry Initiated to a Third Party", "C", "N", "S"]

      expect(followups.map { |followup| down("42", followup).retryable? }).to all(be(false))
    end

    it "retries an 80 whatever its follow-up says" do
      expect([down("80", "Resubmission Not Allowed"), down("80", "C")]).to all(be_retryable)
    end

    it "does not retry any other refusal, even when its follow-up allows it" do
      expect(rejection(code: :name_mismatch, followup: "Resubmission Allowed")).to_not be_retryable
    end
  end

  describe "#resubmission_refused? and #payer_unreached?" do
    def payer(code, reason_code, followup = nil)
      rejection(level: :payer, code: code, reason_code: reason_code,
                followup: followup)
    end

    it "says a 42 with C, N or S was refused as sent, and the payer not unreached" do
      refused = payer(:payer_unavailable, "42", "N")

      expect([refused.resubmission_refused?, refused.payer_unreached?]).to eq([true, false])
    end

    it "says a payer is unreached for a 42 Stedi would ask again, an 80, or a 79" do
      unreached = [payer(:payer_unavailable, "42", "R"), payer(:payer_unavailable, "80", "N"),
                   payer(:invalid_participant, "79", "C")]

      expect(unreached.map { |one| [one.payer_unreached?, one.resubmission_refused?] }).to eq([[true, false]] * 3)
    end

    it "says neither for another refusal" do
      other = payer(:subscriber_not_found, "75", "C")

      expect([other.payer_unreached?, other.resubmission_refused?]).to eq([false, false])
    end
  end

  it "keeps the AAA03 as sent beside the reason it decodes to" do
    expect([rejection(code: :payer_unavailable, reason_code: "80").reason_code,
            rejection(code: :payer_unavailable).reason_code]).to eq(["80", nil])
  end

  describe "#aaa?" do
    it "is an AAA03 X12 publishes, named by the codec or not" do
      expect([rejection(reason_code: "79"), rejection(reason_code: "AA")].map(&:aaa?)).to eq([true, true])
    end

    it "is not a code of Stedi's own, nor no code at all" do
      expect([rejection(reason_code: "BAD_REQUEST"), rejection(code: :input_errors)].map(&:aaa?)).to eq([false, false])
    end
  end

  describe "#our_setup_refused?" do
    it "is a 41 or a T4, which Stedi reads as our setup" do
      expect(%i[authorization_restricted payer_identifier_missing].map { |code| rejection(code: code) })
        .to all(be_our_setup_refused)
    end

    it "is not a refusal of the person" do
      expect(rejection(code: :required_data_missing)).to_not be_our_setup_refused
    end
  end

  describe "#provider_details_wanted?" do
    it "is an address invalid or missing (AAA 97), in any lane" do
      expect([rejection(level: :provider, code: :provider_address_invalid),
              rejection(code: :provider_address_invalid)]).to all(be_provider_details_wanted)
    end

    it "is required data missing (AAA 15) in the provider's lane" do
      expect(rejection(level: :provider, code: :required_data_missing)).to be_provider_details_wanted
    end

    it "is not required data missing about the person" do
      expect(rejection(code: :required_data_missing)).to_not be_provider_details_wanted
    end

    it "is not a refusal of our provider for another reason" do
      expect(rejection(level: :provider, code: :provider_not_on_file)).to_not be_provider_details_wanted
    end
  end

  describe "#summary" do
    it "says the AAA03, the lane and the follow-up's letter" do
      expect(rejection(code: :date_out_of_range, reason_code: "62", followup: "C").summary)
        .to eq("AAA 62 at subscriber, follow-up C")
    end

    it "gives Stedi's follow-up words as their letter" do
      expect(rejection(reason_code: "42", followup: "Do Not Resubmit; Inquiry Initiated to a Third Party").summary)
        .to eq("AAA 42 at subscriber, follow-up S")
    end

    it "leaves out a follow-up that is no AAA04 value" do
      expect(rejection(reason_code: "15", followup: "call us").summary).to eq("AAA 15 at subscriber")
    end

    it "never carries Stedi's free text" do
      summary = rejection(reason_code: "15", description: "JANE DOE missing", resolution: "send JANE DOE").summary

      expect(summary).to_not include("JANE")
    end

    it "names the codec's reason when no AAA03 came" do
      expect(rejection(code: :member_id_invalid).summary).to eq("member_id_invalid at subscriber")
    end

    it "never carries a code that isn't one" do
      expect(rejection(code: "JANE DOE", reason_code: "JANE DOE").summary).to eq("at subscriber")
    end
  end

  describe "#about_provider?" do
    it "is true in the provider lane for a reason other than a payer connection one" do
      expect(rejection(level: :provider, code: :required_data_missing)).to be_about_provider
    end

    it "is true for a provider reason the payer put in the subscriber lane" do
      expect(rejection(code: :provider_not_eligible)).to be_about_provider
    end

    it "is false for a reason about the member" do
      expect(rejection(code: :subscriber_not_found)).to_not be_about_provider
    end

    # Stedi's eligibility troubleshooting page, provider table: 79 is "a problem connecting with
    # this payer" and T4 the payer name or ID we sent, neither a refusal of our provider.
    it "is false for a reason Stedi reads as the payer's in the provider lane" do
      codes = %i[invalid_participant payer_unavailable payer_identifier_missing]

      expect(codes.map { |code| rejection(level: :provider, code: code) })
        .to all(have_attributes(about_provider?: false, about_payer?: true))
    end
  end

  describe "#about_payer?" do
    it "is true for anything in the payer lane" do
      expect(rejection(level: :payer, code: :provider_not_on_file)).to be_about_payer
    end

    it "is false for a provider-lane refusal Stedi reads as about our provider" do
      expect(%i[authorization_restricted provider_not_on_file].map { |code| rejection(level: :provider, code: code) })
        .to all(have_attributes(about_payer?: false, about_provider?: true))
    end

    # Stedi's subscriber and dependent tables give 42 the payer table's resolution.
    it "is true for a 42 or 80 in the person's lanes" do
      expect(%i[subscriber dependent].map { |level| rejection(level: level, code: :payer_unavailable) })
        .to all(be_about_payer)
    end

    it "is false in the person's lanes for a reason those tables don't read as the payer's" do
      expect(%i[invalid_participant payer_identifier_missing subscriber_not_found].map { |code| rejection(code: code) })
        .to all(have_attributes(about_payer?: false))
    end
  end

  describe ".level_from" do
    it "recovers the lane from the loop a flattened error list names" do
      expect(described_class.level_from("Loop 2100C")).to eq(:subscriber)
    end

    it "is nil when the location names no loop" do
      expect(described_class.level_from("somewhere")).to be_nil
    end
  end

  describe "#same_refusal_as?" do
    it "matches an entry repeated verbatim in a vendor's flattened list" do
      attrs = { code: :name_mismatch, description: "Invalid/Missing Name", followup: "Correct" }

      expect(rejection(**attrs)).to be_same_refusal_as(described_class.new(level: :envelope, **attrs))
    end
  end

  it "refuses a lane it does not know" do
    expect { described_class.new(level: :nowhere) }.to raise_error(ArgumentError, /nowhere/)
  end
end
