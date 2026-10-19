# frozen_string_literal: true

RSpec.describe EdiGem::Document::Envelope do
  let(:soap) do
    <<~XML
      <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
        <soap:Body>
          <core:COREEnvelopeRealTimeResponse xmlns:core="http://www.caqh.org/SOAP/WSDL/CORERule2.2.0.xsd">
            <core:PayloadType>X12_271_Response_005010X279A1</core:PayloadType>
            <core:ProcessingMode>RealTime</core:ProcessingMode>
            <core:PayloadID>a4d5f8c2-0000-4000-8000-000000000001</core:PayloadID>
            <core:SenderID>EXAMPLEPLAN</core:SenderID>
            <core:ReceiverID>EXAMPLECLINIC</core:ReceiverID>
            <core:CORERuleVersion>2.2.0</core:CORERuleVersion>
            <core:ErrorCode>Success</core:ErrorCode>
            <core:Payload>#{covered_271}</core:Payload>
          </core:COREEnvelopeRealTimeResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  describe "#metadata" do
    it "reads a field regardless of the namespace prefix the sender chose" do
      expect(described_class.new(soap).metadata["SenderID"]).to eq("EXAMPLEPLAN")
    end

    it "reads the CORE rule version" do
      expect(described_class.new(soap).metadata["CORERuleVersion"]).to eq("2.2.0")
    end
  end

  describe "#locate" do
    it "places a segment of the payload where the payload itself places it" do
      expect(described_class.new(soap).locate("EB").map(&:first))
        .to eq(EdiGem::Document::X12.new(covered_271).locate("EB").map(&:first))
    end
  end

  describe "#error?" do
    it "is false when the envelope reports Success" do
      expect(described_class.new(soap)).not_to be_error
    end

    it "is true for an ErrorCode the rule defines as a refusal" do
      refused = soap.sub("Success", "UnAuthorized")

      expect(described_class.new(refused)).to be_error
    end

    it "is true when the payload type is the envelope error type" do
      refused = soap.sub("X12_271_Response_005010X279A1", "CoreEnvelopeError")

      expect(described_class.new(refused)).to be_error
    end
  end

  it "hands the X12 inside it to a document that can read it" do
    expect(described_class.new(soap).records("EB").first.value("EB01")).to eq("1")
  end
end
