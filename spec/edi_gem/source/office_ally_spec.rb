# frozen_string_literal: true

# Office Ally, over the CAQH CORE envelope: a stub written from the vendor's published
# companion guide and the CORE connectivity rule, never called. These specs pin what the source
# sends and how it reads what those documents describe, not what Office Ally answers.
RSpec.describe EdiGem::Source::OfficeAlly do
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC") }

  def inquiry(subscriber, payer_code: "OA001")
    EdiGem::Inquiry::Eligibility.new(payer_code: payer_code, payer_name: "EXAMPLE HEALTH PLAN",
                                     subscriber: subscriber, provider: provider)
  end

  def full_subscriber
    EdiGem::Subscriber.new(member_id: "MEM123", last_name: "LOVELACE", date_of_birth: "19800101")
  end

  it_behaves_like "a source" do
    let(:source) { described_class.new(credential: enrolled(:office_ally)) }
    let(:inquiry) { EdiGem::Inquiry::Eligibility.new(payer_code: "OA001", subscriber: full_subscriber, provider: provider) }
  end

  describe "what it says it can do" do
    subject(:source) { described_class.new(credential: enrolled(:office_ally)) }

    it "offers eligibility and not discovery" do
      expect(source.capabilities).to include(eligibility: true, discovery: false)
    end

    # The CORE batch envelopes are built below, but CORE has no batch status call, so the
    # contract's batch methods are not offered.
    it "does not offer the contract's batch lane" do
      expect(source.capabilities[:batch]).to be(false)
    end
  end

  # The companion guide's one primary search option.
  describe "the identifiers it will match on" do
    subject(:source) { described_class.new(credential: enrolled(:office_ally)) }

    it "declares exactly the guide's one primary search option" do
      expect(source.search_options).to eq([%i[member_id last_name date_of_birth]])
    end

    it "refuses a name-and-birth-date inquiry before sending it" do
      named = EdiGem::Subscriber.new(first_name: "ADA", last_name: "LOVELACE",
                                     date_of_birth: "19800101")

      expect { source.eligibility(inquiry(named)) }
        .to raise_error(EdiGem::IdentifiersNotAccepted, /office_ally matches on/)
    end

    it "refuses an inquiry with a member id and no birth date" do
      partial = EdiGem::Subscriber.new(member_id: "MEM123", last_name: "LOVELACE")

      expect { source.eligibility(inquiry(partial)) }
        .to raise_error(EdiGem::IdentifiersNotAccepted)
    end
  end

  describe "before the trading partner agreement is signed" do
    it "refuses to send without the identifiers assigned at enrolment" do
      unassigned = EdiGem::Credential.new(provider: nil, source: :office_ally,
                                          values: { endpoint: "https://example.invalid" })
      source = described_class.new(credential: unassigned)

      expect { source.eligibility(inquiry(full_subscriber)) }
        .to raise_error(EdiGem::CredentialMissing, /assigns sender_id/)
    end

    it "refuses to send without the endpoint, which is not published" do
      source = described_class.new(credential: enrolled(:office_ally, endpoint: nil))

      expect { source.eligibility(inquiry(full_subscriber)) }
        .to raise_error(EdiGem::CredentialMissing, /endpoint/)
    end
  end

  describe "the request it builds" do
    subject(:body) { sent_body }

    def sent_body
      source, transport = x12_answering(described_class,
                                        answering(core_answer(covered_271_for("MEM123"))))
      source.eligibility(inquiry(full_subscriber), trace: "T1")
      transport.paths
      source.send(:request_body, inquiry(full_subscriber), trace: "T1")
    end

    it "wraps the 270 in a CORE real-time envelope" do
      expect(body).to include("<core:COREEnvelopeRealTimeRequest>")
    end

    it "declares the payload type the rule enumerates for a 270" do
      expect(body).to include("<PayloadType>X12_270_Request_005010X279A1</PayloadType>")
    end

    it "addresses their documented default receiver" do
      expect(body).to include("<ReceiverID>OFFALLY</ReceiverID>")
    end

    it "routes on the payer code the inquiry carries" do
      expect(body).to include("PI*OA001")
    end

    it "carries the whole interchange as the payload, ISA included" do
      expect(body).to include("<Payload>ISA*00*")
    end

    # The rule requires PayloadLength for batch and forbids it for real time.
    it "sends no PayloadLength on a real-time request" do
      expect(body).to_not include("PayloadLength")
    end
  end

  it "refuses to archive, because it keeps no bodies" do
    source, transport = x12_answering(described_class,
                                      answering(core_answer(covered_271_for("MEM123"))))

    expect { source.eligibility(inquiry(full_subscriber), archive: { name: "x" }) }
      .to raise_error(EdiGem::FeatureNotSupported, /office_ally does not archive/)
    expect(transport.paths).to be_empty
  end

  it "refuses an inquiry with no payer code before sending" do
    source, transport = x12_answering(described_class,
                                      answering(core_answer(covered_271_for("MEM123"))))

    expect { source.eligibility(inquiry(full_subscriber, payer_code: nil)) }
      .to raise_error(EdiGem::PayerNotRouted, /office_ally/)
    expect(transport.paths).to be_empty
  end

  describe "reading what comes back" do
    it "reads coverage out of the 271 inside the envelope" do
      source, = x12_answering(described_class, answering(core_answer(covered_271_for("MEM123"))))

      expect(source.eligibility(inquiry(full_subscriber)).state).to eq(:complete)
    end

    it "carries the trace number the answer is paired with" do
      source, = x12_answering(described_class, answering(core_answer(covered_271_for("MEM123"))))

      expect(source.eligibility(inquiry(full_subscriber), trace: "T1").trace_id).to eq("T1")
    end

    it "reads a subscriber AAA as the member not being identified" do
      source, = x12_answering(described_class, answering(core_answer(rejected_271_for("MEM123"))))

      expect(source.eligibility(inquiry(full_subscriber)).state).to eq(:not_identified)
    end

    # An envelope refusal carries no AAA; it must not read as no coverage.
    describe "an envelope error, which carries no AAA" do
      subject(:response) do
        source, = x12_answering(described_class,
                                answering(core_error("SenderIDIllegal", "SenderID length")))
        source.eligibility(inquiry(full_subscriber))
      end

      it "is a rejection and not an absence of coverage" do
        expect(response.state).to eq(:rejected)
      end

      it "records it in the envelope lane, which is ours to fix and not the payer's" do
        expect(response.rejections_at(:envelope).first.code).to eq("SenderIDIllegal")
      end
    end

    describe "a 999 refusing the transmission, which arrives as a 200 with no 271 in it" do
      subject(:response) do
        source, = x12_answering(described_class, answering(core_answer(functional_acknowledgement)))
        source.eligibility(inquiry(full_subscriber))
      end

      it "is a rejection and not an absence of coverage" do
        expect(response.state).to eq(:rejected)
      end

      it "records it in the envelope lane, which is ours to fix and not the payer's" do
        expect(response.rejections_at(:envelope).map(&:code)).to eq(["5"])
      end
    end
  end

  describe "the CORE batch envelopes" do
    subject(:source) { described_class.new(credential: enrolled(:office_ally), now: Time.at(0)) }

    let(:members) do
      %w[MEM1 MEM2].map do |id|
        inquiry(EdiGem::Subscriber.new(member_id: id, last_name: "LOVELACE",
                                       date_of_birth: "19800101"))
      end
    end
    let(:submission) { source.batch_submission(members) }

    it "declares the payload type the rule enumerates for a batch submission" do
      expect(submission.metadata["PayloadType"])
        .to eq("X12_005010_Request_BatchSubmissionMixed")
    end

    it "carries the payload length, which a real-time request may not" do
      expect(submission.metadata["PayloadLength"]).to match(/\A[1-9]\d*\z/)
    end

    it "states the length in bytes rather than in characters" do
      expect(submission.metadata["PayloadLength"].to_i).to be > 500
    end

    it "puts every member in one interchange rather than one each" do
      expect(submission.soap.scan("ISA*00*").length).to eq(1)
    end

    # ST02 must be unique within a functional group.
    it "numbers each transaction set separately" do
      expect(submission.soap).to include("ST*270*0001*", "ST*270*0002*")
    end

    it "gives each member their own trace number, which is what pairs the answers back" do
      traces = submission.soap.scan(/TRN\*1\*([^*]+)\*/).flatten

      expect(traces.uniq.length).to eq(2)
    end

    describe "collecting the results" do
      it "asks for them by payload id, which is how the file is addressed afterwards" do
        expect(source.batch_results("abc-123").metadata["PayloadID"]).to eq("abc-123")
      end

      it "declares the batch results payload type" do
        expect(source.batch_results("abc-123").metadata["PayloadType"])
          .to eq("X12_005010_Request_Batch_Results_271")
      end

      it "splits a returned file into one answer per member" do
        expect(source.read_batch(batch_271("MEM1", "MEM2")).length).to eq(2)
      end

      # Read whole, the file would mix the ids between answers.
      it "keeps each member's own id with their own answer" do
        answers = source.read_batch(batch_271("MEM1", "MEM2"))
        ids = answers.map { |answer| answer.benefits.filter_map(&:member_id) }

        expect(ids).to eq([%w[MEM1], %w[MEM2]])
      end

      it "reads each one as its own settled response" do
        expect(source.read_batch(batch_271("MEM1", "MEM2")).map(&:state))
          .to eq(%i[complete complete])
      end
    end
  end
end
