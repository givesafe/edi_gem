# frozen_string_literal: true

# Which document a payload becomes, per dialect, including the CAQH CORE envelope reached
# through Payload.
RSpec.describe EdiGem::Document do
  let(:soap_envelope) do
    <<~XML
      <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
        <soap:Body>
          <core:COREEnvelopeRealTimeResponse xmlns:core="http://www.caqh.org/SOAP/WSDL/CORERule2.2.0.xsd">
            <PayloadType>X12_271_Response_005010X279A1</PayloadType>
            <ProcessingMode>RealTime</ProcessingMode>
            <SenderID>PAYER</SenderID>
            <ReceiverID>EXAMPLECLINIC</ReceiverID>
            <ErrorCode>Success</ErrorCode>
            <Payload>ISA*00*          *00*          *ZZ*SENDER         *ZZ*RECEIVER       *260904*0151*^*00501*000000001*0*T*:~EB*1**30~SE*3*0001~IEA*1*000000001~</Payload>
          </core:COREEnvelopeRealTimeResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  describe ".for" do
    it "reads a json payload as a Json document" do
      payload = EdiGem::Payload.new(body: "{}", dialect: :json)

      expect(described_class.for(payload)).to be_a(EdiGem::Document::Json)
    end

    it "reads an x12 payload as an X12 document" do
      payload = EdiGem::Payload.new(body: "ISA*00~", dialect: :x12)

      expect(described_class.for(payload)).to be_a(EdiGem::Document::X12)
    end

    it "reads a soap payload as a CORE Envelope" do
      payload = EdiGem::Payload.new(body: soap_envelope, dialect: :soap)

      expect(described_class.for(payload)).to be_a(EdiGem::Document::Envelope)
    end

    it "reads a mime payload as a CORE Envelope, which is the rule's other form" do
      payload = EdiGem::Payload.new(body: soap_envelope, dialect: :mime)

      expect(described_class.for(payload)).to be_a(EdiGem::Document::Envelope)
    end
  end

  # A dialect Payload accepts and Document has no arm for would be a source wired up halfway.
  it "refuses a dialect it has no document for" do
    payload = EdiGem::Payload.new(body: "{}", dialect: :json)
    allow(payload).to receive(:dialect).and_return(:edifact)

    expect { described_class.for(payload) }.to raise_error(ArgumentError, /no document/)
  end

  describe "the abstract record" do
    it "refuses to answer for a value" do
      expect { EdiGem::Document::Record.new({}).value("anything") }
        .to raise_error(NotImplementedError)
    end
  end

  describe "an envelope reached through a payload" do
    subject(:document) do
      described_class.for(EdiGem::Payload.new(body: soap_envelope, dialect: :soap))
    end

    it "answers envelope metadata by CORE field name" do
      expect(document.one("envelope", "SenderID")).to eq("PAYER")
    end

    # The address that is NOT the envelope falls through to the X12 inside it, which is the
    # whole point of the dialect: one schema reads the 271 whether it arrived bare or wrapped.
    it "reads the X12 inside it at any other address" do
      expect(document.one("EB", "EB01")).to eq("1")
    end
  end

  describe "the abstract document" do
    it "refuses to answer for an address" do
      expect { described_class.new.records("EB") }.to raise_error(NotImplementedError)
    end

    it "refuses to say where a record sits" do
      expect { described_class.new.locate("EB") }.to raise_error(NotImplementedError)
    end
  end

  # #one reaches through the first record at an address, and an address a payer left out has no
  # records at all. It answers nil rather than raising, because a field being absent is the
  # ordinary case in a 271 and not an error.
  it "answers nil for a field at an address the document does not carry" do
    document = described_class.for(EdiGem::Payload.new(body: soap_envelope, dialect: :soap))

    expect(document.one("AAA", "AAA03")).to be_nil
  end
end
