# frozen_string_literal: true

RSpec.describe EdiGem::Rejection do
  def rejection(**attrs) = described_class.new(level: :subscriber, **attrs)

  describe "#retryable?" do
    # Stedi documents 42 and 80 as retry-immediately, and both arrive carrying an AAA04 that
    # says the opposite. Reading the follow-up alone reported a payer outage as final.
    it "retries a payer that is down even though its follow-up forbids resubmission" do
      down = rejection(level: :payer, code: :payer_unavailable,
                       followup: "Resubmission Not Allowed")

      expect(down).to be_retryable
    end

    it "retries when the follow-up allows it and the code says nothing" do
      expect(rejection(code: :name_mismatch, followup: "Resubmission Allowed")).to be_retryable
    end

    it "does not retry a refusal that needs the request corrected first" do
      expect(rejection(code: :member_id_invalid, followup: "Correct and Resubmit"))
        .to_not be_retryable
    end
  end

  describe "#about_provider?" do
    it "is true in the provider lane whatever the reason" do
      expect(rejection(level: :provider, code: :required_data_missing)).to be_about_provider
    end

    it "is true for a provider reason the payer put in the subscriber lane" do
      expect(rejection(code: :provider_not_eligible)).to be_about_provider
    end

    it "is false for a reason about the member" do
      expect(rejection(code: :subscriber_not_found)).to_not be_about_provider
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
