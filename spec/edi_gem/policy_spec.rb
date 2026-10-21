# frozen_string_literal: true

RSpec.describe EdiGem::Policy do
  describe "the policy shipped in data/sources.yml" do
    subject(:stedi) { described_class.for(:stedi) }

    it "knows where to send a request" do
      expect(stedi.base_url).to eq("https://healthcare.us.stedi.com")
    end

    it "resolves a named path, so no path is written into a source class" do
      expect(stedi.path_for(:eligibility)).to match(%r{/eligibility/v3\z})
    end

    it "retries more than once, or the retry layer does nothing" do
      expect(stedi.attempts).to be > 1
    end

    # The bug this guards: YAML 1.1 reads a bare `on:` key as the boolean true, which put this
    # list somewhere nothing read and disabled every retry while every other spec stayed green.
    it "actually retries a rate limit" do
      expect(stedi.retry?(:rate_limited)).to be(true)
    end

    it "actually retries a failing vendor" do
      expect(stedi.retry?(:vendor_unavailable)).to be(true)
    end

    it "never retries a refused credential" do
      expect(stedi.retry?(:not_authorized)).to be(false)
    end

    it "paces its requests" do
      expect(stedi.throttle_per_second).to be_positive
    end

    it "raises for a source with no policy rather than defaulting one" do
      expect { described_class.for(:availity) }.to raise_error(EdiGem::UnknownSchema, /availity/)
    end
  end

  describe "mapping a status onto our vocabulary" do
    subject(:policy) { described_class.for(:stedi) }

    it "matches an exact code first" do
      expect(policy.kind_for_status(429)).to eq(:rate_limited)
    end

    it "falls back to the status class" do
      expect(policy.kind_for_status(503)).to eq(:vendor_unavailable)
    end

    it "reads a credential refusal as such rather than as a bad request" do
      expect(policy.kind_for_status(401)).to eq(:not_authorized)
    end

    it "returns nothing for a status it does not map" do
      expect(policy.kind_for_status(200)).to be_nil
    end
  end

  describe "mapping an exception onto our vocabulary" do
    subject(:policy) { described_class.for(:stedi) }

    it "maps a read timeout" do
      expect(policy.kind_for_exception(Net::ReadTimeout.new)).to eq(:timeout)
    end

    # Net::HTTP raises subclasses, and an unmatched one would read as :unexpected and never retry.
    it "matches up the ancestry rather than on the exact class" do
      subclass = Class.new(SocketError).new
      expect(policy.kind_for_exception(subclass)).to eq(:unreachable)
    end

    it "falls back to unexpected for something it has no row for" do
      expect(policy.kind_for_exception(ArgumentError.new)).to eq(:unexpected)
    end
  end

  describe "a source overriding the defaults" do
    let(:path) { File.expand_path("../fixtures/sources.yml", __dir__) }

    it "keeps the default it did not mention" do
      expect(described_class.for(:partial, path: path).timeout).to eq(30)
    end

    it "takes the value it did mention" do
      expect(described_class.for(:partial, path: path).throttle_per_second).to eq(2)
    end

    it "merges a single status override without losing the rest of the table" do
      policy = described_class.for(:partial, path: path)
      expect(policy.kind_for_status(429)).to eq(:rate_limited)
    end

    it "lets a source restate what one status means to it" do
      policy = described_class.for(:partial, path: path)
      expect(policy.kind_for_status(403)).to eq(:malformed_request)
    end
  end

  # The statuses Stedi's documentation says it answers with, against the policy we actually ship
  # rather than against a fixture. A mapping that is right in the test file and absent from the
  # shipped data reads as covered and is not.
  describe "the shipped Stedi policy" do
    subject(:policy) { described_class.for(:stedi) }

    it "waits out a throttle rather than reporting it as a failure" do
      expect(policy.retry?(policy.kind_for_status(429))).to be(true)
    end

    # We send an Idempotency-Key, so this is the vendor saying the first attempt is still running.
    it "waits on the 409 an idempotent retry provokes" do
      expect(policy.kind_for_status(409)).to eq(:already_in_flight)
      expect(policy.retry?(:already_in_flight)).to be(true)
    end

    it "does not retry a request the vendor rejected as invalid" do
      expect(policy.retry?(policy.kind_for_status(400))).to be(false)
    end

    it "does not retry a refused credential" do
      expect(policy.retry?(policy.kind_for_status(401))).to be(false)
    end
  end

  describe "#error_table" do
    it "lists every mapping, because a map nobody can read whole is not maintainable" do
      triggers = described_class.for(:stedi).error_table.map { |row| row[:trigger] }
      expect(triggers).to include("HTTP 429", "Net::ReadTimeout")
    end

    it "says of each whether it is retried" do
      row = described_class.for(:stedi).error_table.find { |r| r[:trigger] == "HTTP 429" }
      expect(row[:retried]).to be(true)
    end
  end

  describe "#credentials_for" do
    it "names the keys a payer needs, by the source's payer code" do
      expect(described_class.for(:stedi).credentials_for("100065")).to eq([:portal_password])
    end

    it "is empty for a payer with no entry" do
      expect(described_class.for(:stedi).credentials_for("12345")).to eq([])
    end
  end

  # An operation the source asks for and the policy file does not declare. It raises rather than
  # returning the vendor-wide defaults, because a policy with no `path` would build a request
  # against the base URL and post PHI at whatever answers there.
  describe "#for_operation" do
    it "refuses an operation the source does not declare" do
      expect { described_class.for(:stedi).for_operation(:claims) }
        .to raise_error(EdiGem::UnknownSchema, /stedi has no claims operation/)
    end
  end

  describe ".for with retry:" do
    subject(:ours) { described_class.for(:stedi, retry: { attempts: 5, backoff: 2 }) }

    it "takes the caller's attempts" do
      expect(ours.attempts).to eq(5)
    end

    it "takes the caller's backoff" do
      expect(ours.delay_before(2, random: Struct.new(:rand).new(0.5))).to eq(2)
    end

    it "keeps the source's other retry settings" do
      expect(ours.retry?(:rate_limited)).to be(true)
    end

    it "keeps the rest of the source's policy" do
      expect(ours.path_for(:eligibility)).to eq(described_class.for(:stedi).path_for(:eligibility))
    end

    it "reaches the policy of each operation" do
      expect(ours.for_operation(:discovery).attempts).to eq(5)
    end

    it "accepts string keys, as the YAML file spells them" do
      expect(described_class.for(:stedi, retry: { "attempts" => 2 }).attempts).to eq(2)
    end

    it "leaves the policy held for the source as it was" do
      ours

      expect(described_class.for(:stedi).attempts).to eq(3)
    end

    it "is the held policy itself when nothing is overridden" do
      expect(described_class.for(:stedi)).to be(described_class.for(:stedi))
    end

    it "refuses a retry setting it does not have, so a typo is not ignored" do
      expect { described_class.for(:stedi, retry: { attempt: 5 }) }
        .to raise_error(ArgumentError, /unknown retry settings attempt/)
    end

    it "refuses to override anything but retry" do
      expect { described_class.for(:stedi, timeout: 5) }
        .to raise_error(ArgumentError, /cannot override timeout; only retry:/)
    end

    it "still raises for a source with no policy" do
      expect { described_class.for(:availity, retry: { attempts: 1 }) }
        .to raise_error(EdiGem::UnknownSchema, /availity/)
    end
  end

  describe "#with" do
    it "answers a policy that behaves as this one when given nothing" do
      held = described_class.for(:stedi)

      expect(held.with.attempts).to eq(held.attempts)
    end

    it "overrides retry settings on a policy a caller already holds" do
      expect(described_class.for(:stedi).with(retry: { attempts: 4 }).attempts).to eq(4)
    end
  end

  describe ".reload" do
    it "reads sources.yml again rather than answering from the class-level cache" do
      described_class.for(:stedi)
      described_class.reload

      expect(described_class.for(:stedi).name).to eq(:stedi)
    end
  end
end
