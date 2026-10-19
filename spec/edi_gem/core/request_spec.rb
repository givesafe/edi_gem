# frozen_string_literal: true

# The CAQH CORE Connectivity vC2.2.0 envelope, written. Document::Envelope already reads one.
#
# Values are from the rule's metadata table (§4.4.2) and PayloadType enumeration (§4.4.3).
RSpec.describe EdiGem::Core::Request do
  subject(:request) do
    described_class.new(payload: "ISA*00~SE*1~", sender: "EXAMPLECLINIC", receiver: "OFFALLY",
                        payload_id: "0d8f2b1e-1111-4222-8333-444455556666",
                        now: Time.utc(2026, 9, 4, 13, 45, 0))
  end

  describe "the metadata every envelope carries" do
    it "names the payload type from the rule's enumeration" do
      expect(request.metadata["PayloadType"]).to eq("X12_270_Request_005010X279A1")
    end

    it "declares real time unless the caller asked for batch" do
      expect(request.metadata["ProcessingMode"]).to eq("RealTime")
    end

    it "declares the rule version, which a mismatch is refused over" do
      expect(request.metadata["CORERuleVersion"]).to eq("2.2.0")
    end

    # The rule's dateTime constraint. A local-zone stamp is accepted by some receivers and
    # refused by others, and the difference is invisible until a payer in another zone is added.
    it "stamps the time in UTC" do
      expect(request.metadata["TimeStamp"]).to eq("2026-09-04T13:45:00Z")
    end

    # The rule requires an ISO UUID and says the SAME id is reused when a payload is resent
    # without confirmation of receipt -- which makes it the resend key rather than a hash of
    # the content, so it is generated rather than derived.
    it "generates a UUID when the caller named none" do
      expect(described_class.new(payload: "", sender: "S", receiver: "R").payload_id)
        .to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    it "keeps the id the caller named, which is how a resend stays one payload" do
      expect(request.payload_id).to eq("0d8f2b1e-1111-4222-8333-444455556666")
    end
  end

  # "Required for Batch interactions... Shall not be used for Real time." Both directions are
  # explicit in the rule and getting either wrong is an envelope error, not a spare field.
  describe "PayloadLength, which the mode decides" do
    it "is absent on a real-time request" do
      expect(request.metadata).to_not have_key("PayloadLength")
    end

    it "is present on a batch submission" do
      expect(batch.metadata["PayloadLength"]).to eq("12")
    end

    it "counts bytes rather than characters, which differ once a name is not ASCII" do
      wide = described_class.new(payload: "ISA*Ñ~", sender: "S", receiver: "R",
                                 mode: described_class::BATCH)

      expect(wide.metadata["PayloadLength"]).to eq("7")
    end
  end

  describe "the SOAP form" do
    it "carries the payload inside the real-time request element" do
      expect(request.soap).to include("<core:COREEnvelopeRealTimeRequest>")
    end

    it "names the batch submission element in batch mode" do
      expect(batch.soap).to include("<core:COREEnvelopeBatchSubmission>")
    end

    it "names the retrieval element when collecting results" do
      expect(results.soap).to include("<core:COREEnvelopeBatchResultsRetrievalRequest>")
    end

    # An X12 payload carries no XML metacharacters of its own, but a payer name inside one can
    # carry an ampersand, and one is enough to make the envelope unparseable at the receiver.
    it "escapes a payer name that carries an ampersand" do
      named = described_class.new(payload: "NM1*PR*2*SMITH & SONS~", sender: "S", receiver: "R")

      expect(named.soap).to include("SMITH &amp; SONS")
    end
  end

  # Required by the rule only when X.509 client-certificate authentication is not used. Office
  # Ally issues client certificates and acts as its own CA, so theirs is the empty case.
  describe "the WS-Security header" do
    it "is empty when the receiver authenticates by client certificate" do
      expect(request.soap).to include("<soap:Header></soap:Header>")
    end

    it "carries a username token when the receiver authenticates that way instead" do
      named = described_class.new(payload: "", sender: "S", receiver: "R",
                                  username: "user", password: "secret")

      expect(named.soap).to include("<wsse:Username>user</wsse:Username>")
    end
  end

  # The other form the rule defines, and the one a caller with no SOAP stack reaches for --
  # which is every caller here, since the gem carries no runtime dependency.
  describe "the MIME multipart form" do
    it "names every metadata field as its own part" do
      expect(request.mime).to include('name="PayloadType"')
    end

    it "carries the payload as a part like any other" do
      expect(request.mime).to include("name=\"Payload\"\r\n\r\nISA*00~SE*1~")
    end

    it "closes the multipart body, which a receiver waits for" do
      expect(request.mime).to end_with("--\r\n")
    end

    it "declares a boundary the body actually uses" do
      expect(request.mime_content_type).to include(request.payload_id)
    end

    it "takes a boundary the caller chose, for a payload that contains the default" do
      expect(request.mime(boundary: "XYZ")).to include("--XYZ--")
    end
  end

  def batch
    described_class.new(payload: "ISA*00~SE*1~", sender: "S", receiver: "R",
                        payload_type: described_class::BATCH_SUBMISSION,
                        mode: described_class::BATCH)
  end

  def results
    described_class.new(payload: "", sender: "S", receiver: "R",
                        payload_type: described_class::BATCH_RESULTS,
                        mode: described_class::BATCH)
  end
end
