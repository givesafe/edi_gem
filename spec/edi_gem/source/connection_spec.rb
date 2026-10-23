# frozen_string_literal: true

# The HTTP half every source repeats, tested where the specs normally inject past it. Sources are
# specced with a client and a transport handed in, which is right for asserting what a vendor is
# told -- but it means the code that actually builds a client had never run. That code is where a
# client certificate and a kept-open connection will go for the CAQH CORE vendors, so it is worth
# more than its size.
RSpec.describe EdiGem::Source::Connection do
  subject(:connection) do
    described_class.new(policy: policy, headers: { "Authorization" => "test-key" })
  end

  let(:policy) { EdiGem::Policy.for(:stedi) }
  let(:client) { instance_double(Net::HTTP) }

  # Net::HTTP.new only records host and port -- nothing connects until #request -- so the client
  # build is observable without a socket.
  before do
    allow(Net::HTTP).to receive(:new).and_return(client)
    allow(client).to receive(:use_ssl=)
    allow(client).to receive(:open_timeout=)
    allow(client).to receive(:read_timeout=)
    allow(client).to receive(:request).and_return(response)
  end

  let(:response) do
    instance_double(Net::HTTPOK, code: "200", body: "{}", each_header: {}).tap do |ok|
      allow(ok).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    end
  end

  describe "the client it builds" do
    it "points at the host the policy names" do
      connection.post(:eligibility, "{}")

      expect(Net::HTTP).to have_received(:new).with("healthcare.us.stedi.com", 443)
    end

    it "turns TLS on, which Net::HTTP does not infer from the URL" do
      connection.post(:eligibility, "{}")

      expect(client).to have_received(:use_ssl=).with(true)
    end

    # Timeouts are per operation, not per vendor.
    it "takes its timeouts from the operation's own policy" do
      timeout = policy.for_operation(:eligibility).timeout
      connection.post(:eligibility, "{}")

      expect(client).to have_received(:read_timeout=).with(timeout)
    end
  end

  describe "the request it sends" do
    def sent
      connection.post(:eligibility, '{"x":1}', idempotency_key: "abc")
      request = nil
      expect(client).to have_received(:request) { |sent| request = sent }
      request
    end

    it "carries the vendor's standing headers" do
      expect(sent["Authorization"]).to eq("test-key")
    end

    it "carries the idempotency key when the caller supplied one" do
      expect(sent["Idempotency-Key"]).to eq("abc")
    end

    # A GET has no body to identify, so nothing is sent to identify it with. Asserted because
    # a stray header here is the kind of thing a vendor rejects the whole request over.
    it "sends no idempotency key when the caller supplied none" do
      connection.get(:discovery, "/2024-04-01/insurance-discovery/check/v1/abc")
      request = nil
      expect(client).to have_received(:request) { |sent| request = sent }

      expect(request["Idempotency-Key"]).to be_nil
    end

    it "sends a GET's query on the URL" do
      connection.get(:payer_search, "/2024-04-01/payers/search", query: { query: "99999", pageSize: 100 })
      request = nil
      expect(client).to have_received(:request) { |sent| request = sent }

      expect(request.uri.to_s).to eq("https://healthcare.us.stedi.com/2024-04-01/payers/search?query=99999&pageSize=100")
    end
  end

  # One transport per operation, held for the life of the connection: the throttle it paces
  # against is state, so a fresh one per call would pace against nothing and the rate limit
  # would only be discovered from the vendor's 429s.
  describe "the transport it paces against" do
    it "keeps one per operation rather than building one per call" do
      2.times { connection.post(:eligibility, "{}") }

      expect(connection.send(:transport, :eligibility))
        .to be(connection.send(:transport, :eligibility))
    end

    # Stedi's discovery endpoint is capped at one a second and eligibility at ten, so one
    # transport for the vendor would pace the whole source at whichever it was built for.
    it "holds a different one per operation, because the rates differ" do
      expect(connection.send(:transport, :eligibility))
        .to_not be(connection.send(:transport, :discovery))
    end
  end

  # For a client certificate, which belongs to the client rather than the request.
  describe "a client the caller built itself" do
    subject(:connection) do
      described_class.new(policy: policy, headers: {}, client: prepared)
    end

    let(:prepared) do
      instance_double(Net::HTTP, request: response).tap do |http|
        allow(http).to receive(:cert).and_return("a client certificate")
      end
    end

    it "sends through it" do
      connection.post(:eligibility, "{}")

      expect(prepared).to have_received(:request)
    end

    it "builds none of its own, so whatever the caller configured survives" do
      connection.post(:eligibility, "{}")

      expect(Net::HTTP).to_not have_received(:new)
    end
  end

  it "records the exchange rather than returning the raw response" do
    expect(connection.post(:eligibility, "{}")).to be_a(EdiGem::Exchange)
  end
end
