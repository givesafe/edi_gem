# frozen_string_literal: true

RSpec.describe EdiGem::Transport do
  # A recording sleeper, so the specs assert the schedule rather than waiting it out.
  let(:slept) { [] }
  let(:sleeper) { double("sleeper") }
  # Built here rather than read from data/sources.yml, so these assert the transport's behaviour
  # and not the shipped policy's current numbers. policy_spec covers the file itself.
  let(:throttle) { nil }
  let(:policy) do
    EdiGem::Policy.new(:test,
                       "timeout" => 5,
                       "retry" => { "attempts" => 3, "backoff" => 1, "multiplier" => 2,
                                    "max_delay" => 20, "jitter" => 0,
                                    "retry_on" => %w[timeout unreachable rate_limited
                                                     vendor_unavailable] },
                       "throttle" => throttle,
                       "errors" => {
                         "retry_after_header" => "Retry-After",
                         "status" => { "401" => "not_authorized", "429" => "rate_limited",
                                       "4xx" => "malformed_request", "5xx" => "vendor_unavailable" },
                         "exceptions" => { "Net::OpenTimeout" => "timeout",
                                           "Errno::ECONNREFUSED" => "unreachable",
                                           "SocketError" => "unreachable" }
                       })
  end
  let(:random) { double("random", rand: 0.5) }

  subject(:transport) do
    described_class.new(policy: policy, sleeper: sleeper, random: random)
  end

  before { allow(sleeper).to receive(:sleep) { |seconds| slept << seconds } }

  def ok = instance_double(Net::HTTPOK).tap { |r| stub_status(r, true) }

  def failing(status, retry_after: nil)
    instance_double(Net::HTTPServiceUnavailable, code: status.to_s).tap do |response|
      stub_status(response, false)
      allow(response).to receive(:[]).with("Retry-After").and_return(retry_after)
    end
  end

  def stub_status(response, success)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(success)
  end

  describe "a call that succeeds" do
    it "returns the vendor's response untouched" do
      response = ok
      expect(transport.perform(path: "/x") { response }).to be(response)
    end

    it "sleeps for nothing" do
      transport.perform(path: "/x") { ok }
      expect(slept).to be_empty
    end
  end

  describe "a status the policy calls retryable" do
    it "retries up to the configured number of attempts" do
      calls = 0
      expect do
        transport.perform(path: "/x") { calls += 1 and failing(503) }
      end.to raise_error(EdiGem::Fault)
      expect(calls).to eq(policy.attempts)
    end

    it "returns the response once one succeeds" do
      responses = [failing(503), ok]
      expect(transport.perform(path: "/x") { responses.shift }).to_not be_nil
    end

    it "backs off further each time rather than resending at a fixed rate" do
      expect { transport.perform(path: "/x") { failing(503) } }.to raise_error(EdiGem::Fault)
      expect(slept).to eq([1, 2])
    end
  end

  # A real-time check waits for Stedi's answer, and asking again stops two minutes after the first
  # send: `retry_until` is that end on the transport's clock.
  describe "a retry that would start after retry_until" do
    let(:clock) { double("clock") }

    subject(:transport) do
      described_class.new(policy: policy, sleeper: sleeper, random: random, clock: clock)
    end

    it "retries while the wait ends before retry_until" do
      allow(clock).to receive(:clock_gettime).and_return(10)
      responses = [failing(503), ok]

      expect(transport.perform(path: "/x", retry_until: 120) { responses.shift }).to_not be_nil
    end

    it "raises the fault rather than wait past retry_until" do
      allow(clock).to receive(:clock_gettime).and_return(119.5)
      calls = 0

      expect { transport.perform(path: "/x", retry_until: 120) { calls += 1 and failing(503) } }
        .to raise_error(EdiGem::Fault)
      expect([calls, slept]).to eq([1, []])
    end

    context "WHEN the policy retries the kind until the end" do
      let(:policy) do
        EdiGem::Policy.new(:test, "retry" => { "attempts" => 3, "backoff" => 1, "multiplier" => 1,
                                               "jitter" => 0, "retry_on" => %w[rate_limited vendor_unavailable],
                                               "retry_until_end" => %w[rate_limited] },
                                  "errors" => { "status" => { "429" => "rate_limited",
                                                              "5xx" => "vendor_unavailable" } })
      end
      let(:seconds) { [0] }

      before { allow(clock).to receive(:clock_gettime) { seconds.first } }

      def tick(response) = response.tap { seconds[0] += 10 }

      # Stedi, eligibility troubleshooting: a 429 is a 42, "Retry immediately", for up to 2 minutes.
      it "retries Stedi busy past its attempts, until the end" do
        calls = 0

        expect { transport.perform(path: "/x", retry_until: 120) { (calls += 1) && tick(failing(429)) } }
          .to raise_error(an_instance_of(EdiGem::Fault).and(having_attributes(kind: :rate_limited)))
        # Each send takes 10 s: sends start at 0, 10, ... 110 s; the next would start past 120.
        expect(calls).to eq(12)
      end

      it "returns the response once a retry past its attempts succeeds" do
        responses = [failing(429), failing(429), failing(429), ok]

        expect(transport.perform(path: "/x", retry_until: 120) { tick(responses.shift) }).to_not be_nil
      end

      it "keeps to its attempts for another kind" do
        calls = 0

        expect { transport.perform(path: "/x", retry_until: 120) { (calls += 1) && tick(failing(503)) } }
          .to raise_error(EdiGem::Fault)
        expect(calls).to eq(3)
      end

      it "keeps to its attempts for a send with no end" do
        calls = 0

        expect { transport.perform(path: "/x") { (calls += 1) && tick(failing(429)) } }.to raise_error(EdiGem::Fault)
        expect(calls).to eq(3)
      end
    end

    # The eligibility timeout (125 s) is longer than the two minutes, so a timed-out check is never
    # sent again, whatever attempts the caller's policy allows.
    it "never retries a timeout that came after retry_until" do
      allow(clock).to receive(:clock_gettime).and_return(125)
      calls = 0

      expect { transport.perform(path: "/x", retry_until: 120) { (calls += 1) && raise(Net::OpenTimeout) } }
        .to raise_error(an_instance_of(EdiGem::Fault).and(having_attributes(kind: :timeout)))
      expect(calls).to eq(1)
    end
  end

  describe "a status the policy calls terminal" do
    it "raises without a second attempt" do
      calls = 0
      expect do
        transport.perform(path: "/x") { calls += 1 and failing(401) }
      end.to raise_error(EdiGem::Fault)
      expect(calls).to eq(1)
    end

    it "raises the commonized meaning rather than the vendor's status" do
      expect { transport.perform(path: "/x") { failing(401) } }
        .to raise_error(an_object_having_attributes(kind: :not_authorized))
    end
  end

  describe "a status whose body the policy reads for an answer" do
    let(:policy) do
      EdiGem::Policy.new(:test, "errors" => { "status" => { "4xx" => "malformed_request" },
                                              "answer_in_status" => %w[400] })
    end

    it "returns the response, to be read" do
      response = failing(400)
      expect(transport.perform(path: "/x") { response }).to be(response)
    end

    it "raises any other failing status from its status alone" do
      expect { transport.perform(path: "/x") { failing(404) } }
        .to raise_error(an_object_having_attributes(kind: :malformed_request, status: 404, path: "/x"))
    end
  end

  describe "a vendor that says when to come back" do
    it "waits exactly that long instead of our own backoff" do
      responses = [failing(429, retry_after: "7"), ok]
      transport.perform(path: "/x") { responses.shift }
      expect(slept).to eq([7])
    end

    it "falls back to our backoff when the vendor sends no header" do
      responses = [failing(429), ok]
      transport.perform(path: "/x") { responses.shift }
      expect(slept).to eq([1])
    end
  end

  describe "an exception raised by the connection" do
    it "becomes a timeout fault rather than escaping as a net/http error" do
      expect { transport.perform(path: "/x") { raise Net::OpenTimeout } }
        .to raise_error(an_object_having_attributes(kind: :timeout))
    end

    it "becomes an unreachable fault for a refused connection" do
      expect { transport.perform(path: "/x") { raise Errno::ECONNREFUSED } }
        .to raise_error(an_object_having_attributes(kind: :unreachable))
    end

    it "is caught as EdiGem::Error, which a raw net/http error would not be" do
      expect { transport.perform(path: "/x") { raise SocketError } }
        .to raise_error(EdiGem::Error)
    end

    it "falls back to unexpected rather than passing an unmapped error through" do
      expect { transport.perform(path: "/x") { raise ArgumentError, "surprise" } }
        .to raise_error(an_object_having_attributes(kind: :unexpected))
    end

    # ScriptError is not StandardError, and a transport that swallowed one would hide a genuine
    # programming fault behind a retry.
    it "does not catch an error outside StandardError" do
      expect { transport.perform(path: "/x") { raise NotImplementedError } }
        .to raise_error(NotImplementedError)
    end
  end

  describe "an error this gem raised on purpose" do
    it "passes through, because it is a result and not a transport failure" do
      expect { transport.perform(path: "/x") { raise EdiGem::PayerNotRouted } }
        .to raise_error(EdiGem::PayerNotRouted)
    end
  end

  describe "the throttle" do
    context "when the policy sets a rate" do
      let(:throttle) { { "per_second" => 10 } }

      it "paces the second call rather than opening as fast as the loop runs" do
        2.times { transport.perform(path: "/x") { ok } }
        expect(slept.size).to eq(1)
      end

      it "waits no longer than the interval the rate implies" do
        2.times { transport.perform(path: "/x") { ok } }
        expect(slept.first).to be <= 0.1
      end
    end

    it "does not pace at all when the policy sets no rate" do
      2.times { transport.perform(path: "/x") { ok } }
      expect(slept).to be_empty
    end
  end

  # The other half of the throttle: a caller that was already slower than the rate waits for
  # nothing. Without this, a batch that spends a second per response would sleep on every call.
  describe "a caller already slower than the rate" do
    let(:throttle) { { "per_second" => 10 } }
    let(:clock) { double("clock") }

    subject(:transport) do
      described_class.new(policy: policy, sleeper: sleeper, random: random, clock: clock)
    end

    # Three readings, because pace reads the clock once on the first call (its ensure) and
    # twice on the second -- to work out the wait, and to record when this call started.
    it "does not sleep when more than the interval has already passed" do
      allow(clock).to receive(:clock_gettime).and_return(0.0, 5.0, 5.0)

      2.times { transport.perform(path: "/x") { ok } }

      expect(slept).to be_empty
    end
  end
end
