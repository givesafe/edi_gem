# frozen_string_literal: true

RSpec.describe EdiGem::Exchange do
  subject(:exchange) do
    described_class.new(method: :post, url: "https://example.test/eligibility",
                        request_headers: { "Authorization" => "sk_live_x" },
                        request_body: '{"subscriber":{"memberId":"MEM123"}}',
                        status: 200, response_body: covered_271)
  end

  describe "#failing_status?" do
    def with_status(status) = described_class.new(method: :post, url: "https://example.test", status: status)

    it "is an HTTP status that is no success" do
      expect([400, 503, 302].map { |status| with_status(status).failing_status? }).to eq([true, true, true])
    end

    it "is not a success, nor no status at all" do
      expect([200, 204, nil].map { |status| with_status(status).failing_status? }).to eq([false, false, false])
    end
  end

  it "keeps the response body byte for byte, whatever dialect it is in" do
    expect(exchange.response_body).to eq(covered_271)
  end

  it "serialises both halves of the call for the payload store" do
    expect(exchange.to_h.keys)
      .to include(:method, :url, :request_headers, :request_body, :status, :response_body)
  end

  it "never prints the credential its headers carry" do
    expect(exchange.inspect).not_to include("sk_live_x")
  end

  it "never prints the PHI its bodies carry" do
    expect(exchange.inspect).not_to include("MEM123")
  end

  # A call that never started has no clock reading, and to_h is what the payload store writes.
  # A nil here has to stay nil rather than raising on #iso8601 while a response is being recorded.
  it "serialises a call with no start time rather than raising on it" do
    unstarted = described_class.new(method: :post, url: "https://example.test/x", status: 0)

    expect(unstarted.to_h[:started_at]).to be_nil
  end

  it "writes the start time as ISO 8601, because the store is read outside this process" do
    started = described_class.new(method: :post, url: "https://example.test/x", status: 200,
                                  started_at: Time.at(0).utc)

    expect(started.to_h[:started_at]).to eq("1970-01-01T00:00:00Z")
  end
end
