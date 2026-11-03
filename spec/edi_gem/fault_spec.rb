# frozen_string_literal: true

RSpec.describe EdiGem::Fault do
  def fault(kind, **attrs) = described_class.new(kind: kind, **attrs)

  describe "the error table" do
    it "gives every kind a retryable answer, so no caller has to guess" do
      expect(described_class::KINDS.values).to all(include(:retryable))
    end

    it "gives every kind a lane, so a fault can be recorded as a rejection" do
      levels = described_class::KINDS.values.map { |row| row[:level] }
      expect(levels).to all(satisfy { |level| EdiGem::Rejection::LEVELS.include?(level) })
    end

    it "refuses a kind that is not in the table" do
      expect { fault(:invented) }.to raise_error(ArgumentError, /invented/)
    end
  end

  describe ".of_status" do
    let(:policy) { EdiGem::Policy.for(:stedi) }

    it "is the Fault a status means under the source's policy, where it was sent" do
      expect(described_class.of_status(400, policy: policy, path: "/x"))
        .to have_attributes(kind: :malformed_request, source: :stedi, status: 400, path: "/x")
    end

    it "is unexpected for a status the policy does not map" do
      expect(described_class.of_status(302, policy: policy, path: "/x").kind).to eq(:unexpected)
    end
  end

  describe "retryability, which belongs to the meaning and not to the vendor" do
    it "retries a rate limit" do
      expect(fault(:rate_limited)).to be_retryable
    end

    it "retries a vendor that is failing" do
      expect(fault(:vendor_unavailable)).to be_retryable
    end

    it "does not retry a refused credential" do
      expect(fault(:not_authorized)).to_not be_retryable
    end

    it "does not retry a request the vendor called invalid" do
      expect(fault(:malformed_request)).to_not be_retryable
    end
  end

  describe "the message" do
    it "names the source, the kind and the status" do
      message = fault(:rate_limited, source: :stedi, status: 429, path: "/x").message
      expect(message).to include("stedi", "rate_limited", "429", "/x")
    end

    # A 271 body is PHI and an error is a thing that gets logged.
    it "cannot carry a response body at all" do
      expect(described_class.instance_method(:initialize).parameters.map(&:last))
        .to_not include(:body)
    end
  end
end
