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

  describe "#to_rejection" do
    it "records a timeout in the transport lane, which nothing else fills" do
      expect(fault(:timeout).to_rejection.level).to eq(:transport)
    end

    it "carries the kind as the code, so a batch can group failures" do
      expect(fault(:timeout).to_rejection.code).to eq(:timeout)
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

  describe "#to_rejection on a fault nobody should retry" do
    it "offers no follow-up action, because there is none to offer" do
      expect(fault(:not_authorized).to_rejection.followup).to be_nil
    end

    it "records the envelope level, because a refused credential is not the payer's answer" do
      expect(fault(:not_authorized).to_rejection.level).to eq(:envelope)
    end
  end
end
