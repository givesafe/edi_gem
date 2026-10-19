# frozen_string_literal: true

# 271s and CORE envelopes for the X12 sources, written from the implementation guide and Office
# Ally's published examples. They show the reader reads what those documents describe.
module X12Answers
  include X12Fixtures

  def covered_271_for(member_id, payer_code: "00222")
    x12_271("GS*HB*OFFALLY*EXAMPLECLINIC*20260904*1345*1*X*005010X279A1~",
            "ST*271*0001*005010X279A1~",
            "HL*1**20*1~", "NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*#{payer_code}~",
            "HL*2*1*21*1~", "NM1*1P*2*EXAMPLECLINIC*****XX*1999999984~",
            "HL*3*2*22*0~", "NM1*IL*1*LOVELACE*ADA****MI*#{member_id}~",
            "EB*1**30**EXAMPLE MANAGED CARE~",
            "SE*10*0001~", "GE*1*1~", "IEA*1*000000001~")
  end

  def rejected_271_for(member_id)
    x12_271("GS*HB*OFFALLY*EXAMPLECLINIC*20260904*1345*1*X*005010X279A1~",
            "ST*271*0001*005010X279A1~",
            "HL*1**20*1~", "NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*00222~",
            "HL*2*1*21*1~", "NM1*1P*2*EXAMPLECLINIC*****XX*1999999984~",
            "HL*3*2*22*0~", "NM1*IL*1*LOVELACE*ADA****MI*#{member_id}~",
            "AAA*Y**72*C~",
            "SE*10*0001~", "GE*1*1~", "IEA*1*000000001~")
  end

  # A 999 refusing the transmission, arriving as a 200. `transaction` and `group` are the IK501
  # and AK901 verdicts.
  def functional_acknowledgement(transaction: "R", group: "R")
    x12_271("GS*FA*OFFALLY*EXAMPLECLINIC*20260904*1345*1*X*005010X231A1~",
            "ST*999*0001*005010X231A1~",
            "AK1*HS*1*005010X279A1~", "AK2*270*0001*005010X279A1~",
            "IK3*NM1*8*2100C*8~", "IK5*#{transaction}*5~", "AK9*#{group}*1*1*0~",
            "SE*7*0001~", "GE*1*1~", "IEA*1*000000001~")
  end

  # Several answers in one returned file, as a collected batch is.
  def batch_271(*member_ids)
    transactions = member_ids.each_with_index.map do |member_id, index|
      control = format("%<n>04d", n: index + 1)
      ["ST*271*#{control}*005010X279A1~",
       "HL*1**20*1~", "NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*00222~",
       "HL*2*1*21*1~", "NM1*1P*2*EXAMPLECLINIC*****XX*1999999984~",
       "HL*3*2*22*0~", "NM1*IL*1*LOVELACE*ADA****MI*#{member_id}~",
       "EB*1**30~", "SE*9*#{control}~"].join
    end
    x12_271("GS*HB*OFFALLY*EXAMPLECLINIC*20260904*1345*1*X*005010X279A1~",
            *transactions, "GE*#{member_ids.length}*1~", "IEA*1*000000001~")
  end

  # A CORE envelope carrying a 271, which is what Office Ally answers with.
  def core_answer(payload)
    <<~XML
      <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
        <soap:Body>
          <core:COREEnvelopeRealTimeResponse xmlns:core="http://www.caqh.org/SOAP/WSDL/CORETransactions">
            <PayloadType>X12_271_Response_005010X279A1</PayloadType>
            <ProcessingMode>RealTime</ProcessingMode>
            <SenderID>OFFALLY</SenderID>
            <ReceiverID>EXAMPLECLINIC</ReceiverID>
            <CORERuleVersion>2.2.0</CORERuleVersion>
            <ErrorCode>Success</ErrorCode>
            <Payload>#{payload}</Payload>
          </core:COREEnvelopeRealTimeResponse>
        </soap:Body>
      </soap:Envelope>
    XML
  end

  # An envelope refusing the request. It carries no AAA.
  def core_error(code, message)
    <<~XML
      <soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope">
        <soap:Body>
          <core:COREEnvelopeError xmlns:core="http://www.caqh.org/SOAP/WSDL/CORETransactions">
            <PayloadType>CoreEnvelopeError</PayloadType>
            <ErrorCode>#{code}</ErrorCode>
            <ErrorMessage>#{message}</ErrorMessage>
            <Payload></Payload>
          </core:COREEnvelopeError>
        </soap:Body>
      </soap:Envelope>
    XML
  end
end
