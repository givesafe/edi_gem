# frozen_string_literal: true

require "date"

# The app stores these keys, so a key made here must equal the one it made before. The pinned
# digests were computed by the app's own RequestKeys code under the same made-up secret.
RSpec.describe EdiGem::RequestKey do
  let(:secret) { "k" * 32 }
  let(:details) do
    { first_name: "Jane", last_name: "Doe", date_of_birth: Date.new(1980, 1, 1), insurance_id: "ABC123",
      payer_id: "99999", payer_type: "stedi" }
  end
  let(:day) { Date.new(2026, 10, 19) }

  def key(operation = :eligibility, asked = details, on: day, with: secret)
    described_class.idempotency_key(operation, asked, secret: with, on: on)
  end

  def fingerprint(asked = details, with: secret)
    described_class.fingerprint(asked, secret: with)
  end

  describe ".fingerprint" do
    it "is a hex digest holding none of the details" do
      expect(fingerprint).to match(/\A\h{64}\z/)
    end

    it "is the same under case and whitespace" do
      typed = details.merge(first_name: "  JANE ", last_name: "doe", insurance_id: " abc123  ")

      expect(fingerprint(typed)).to eq fingerprint
    end

    it "is the same under inner whitespace, a non-breaking space among it" do
      expect(fingerprint(details.merge(last_name: "Van   Doe"))).to eq fingerprint(details.merge(last_name: "van doe"))
    end

    it "ignores a blank detail" do
      expect(fingerprint(details.merge(ssn: nil, address_line1: " "))).to eq fingerprint
    end

    it "differs when a detail, the payer or the clearinghouse differs" do
      changed = [{ insurance_id: "ABC124" }, { payer_id: "88888" }, { payer_type: "availity" }]

      expect(changed.map { |change| fingerprint(details.merge(change)) }).to_not include fingerprint
    end

    it "differs when the secret differs" do
      expect(fingerprint(with: "another-key".ljust(32, "x"))).to_not eq fingerprint
    end
  end

  describe ".idempotency_key" do
    it "is a hex digest holding none of the details" do
      expect(key).to match(/\A\h{64}\z/)
    end

    it "is the same for the same details on the same day, under case and whitespace" do
      expect(key(:eligibility, details.merge(first_name: "  JANE ", insurance_id: " abc123  "))).to eq key
    end

    it "differs on the next day" do
      expect(key(on: day + 1)).to_not eq key
    end

    it "differs by operation" do
      expect(key(:discovery)).to_not eq key
    end

    it "differs when a detail differs" do
      expect(key(:eligibility, details.merge(insurance_id: "ABC124"))).to_not eq key
    end

    it "differs from the fingerprint of the same details" do
      expect(key).to_not eq fingerprint
    end

    it "differs when the secret differs" do
      expect(key(with: "another-key".ljust(32, "x"))).to_not eq key
    end

    it "takes an operation named as a string" do
      expect(key("eligibility")).to eq key
    end

    it "raises for an operation it doesn't know" do
      expect { key(:refund) }.to raise_error(ArgumentError, /unknown operation/)
    end

    it "gives a batch the key the app gave it" do
      expect(key(:batch, { item_keys: "b,a", payer_id: "99999", payer_type: "stedi" }))
        .to eq "961b0d4f7126fd6f2b51e1f75e5cd293004b4abc05443265c2980388f748b9f6"
    end
  end

  describe "an inquiry's keys" do
    let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic") }
    let(:patient) do
      EdiGem::Subscriber.new(member_id: "ABC123", first_name: "José", last_name: "Van  Doe", date_of_birth: "19800101")
    end

    def check(**people)
      EdiGem::Inquiry::Eligibility.new(payer_code: "99999", provider: provider, subscriber: patient, **people)
    end

    def as_dependent
      dependent = EdiGem::Subscriber.new(first_name: "José", last_name: "Van  Doe", date_of_birth: "19800101",
                                         relationship: nil)
      check(subscriber: EdiGem::Subscriber.new(member_id: "ABC123"), dependent: dependent)
    end

    def discovery(subscriber = patient)
      EdiGem::Inquiry::Discovery.new(subscriber: subscriber, provider: provider, as_of: day)
    end

    let(:addressed) do
      EdiGem::Subscriber.new(first_name: "José", last_name: "Van  Doe", date_of_birth: "19800101",
                             address: EdiGem::Address.new(line1: "1 Example St", postal_code: "40000"))
    end

    it "gives a check asked as the subscriber the key the app gave it" do
      expect(check.idempotency_key(secret: secret, on: day, clearinghouse: :stedi))
        .to eq "96dce56da0f9c8c8d380905d4dac53f25d46179b63594c748d66aa523bcae986"
    end

    it "gives a check asked as a dependent the key the app gave it" do
      expect(as_dependent.idempotency_key(secret: secret, on: day, clearinghouse: "stedi"))
        .to eq "07dd72d05c3e01b317d7bb851dd98780afbef05e1f756bb5cea2e920f3387cef"
    end

    it "gives a check the fingerprint the app gave it, asked either way" do
      fingerprints = [check, as_dependent].map { |asked| asked.fingerprint(secret: secret, clearinghouse: :stedi) }

      expect(fingerprints.uniq).to eq ["94ea0de47974b17bc7aa546cd7fd6b6c5b4db41e37e448d352d3ef764d637610"]
    end

    it "says which way a check asks" do
      expect([check.asked_as, as_dependent.asked_as]).to eq(%i[subscriber dependent])
    end

    it "gives a discovery the key and fingerprint the app gave it" do
      asked = discovery(addressed)

      expect([asked.idempotency_key(secret: secret, on: day), asked.fingerprint(secret: secret)])
        .to eq(%w[ac514e3466765f35016e9d1739aa3d57772f62dc48b3e3439005d211cc306e46
                  ea11b8e0ebb3472ef83a25a7ffa2ce7e5843ea2e11caa113f5ac0d74073b3cbc])
    end

    it "makes a discovery with an SSN a different question" do
      with_ssn = EdiGem::Subscriber.new(first_name: "José", last_name: "Van  Doe", date_of_birth: "19800101",
                                        ssn: "000000000")

      expect(discovery(with_ssn).fingerprint(secret: secret)).to_not eq discovery.fingerprint(secret: secret)
    end

    it "makes a key for a patient with no birth date" do
      undated = EdiGem::Subscriber.new(member_id: "ABC123", last_name: "Doe")

      expect(check(subscriber: undated).idempotency_key(secret: secret, on: day, clearinghouse: :stedi))
        .to match(/\A\h{64}\z/)
    end
  end
end
