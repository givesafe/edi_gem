# frozen_string_literal: true

# A patient on someone else's policy, asked about as a dependent: the subscriber carries the
# policy's member id and the dependent the patient's names and birth date. A real-time answer is
# about the patient asked about, and a payer may move them between the subscriber and dependent
# parts, or ignore the dependent and answer about the subscriber.
RSpec.describe "asking about a dependent" do
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC") }
  let(:policy) { EdiGem::Subscriber.new(member_id: "MOCK00000002") }
  let(:patient) do
    EdiGem::Subscriber.new(first_name: "Testfirst", last_name: "Testlast",
                           date_of_birth: "20100101", relationship: :child)
  end

  def inquiry(dependent: patient)
    EdiGem::Inquiry::Eligibility.new(payer_code: "77027", subscriber: policy,
                                     dependent: dependent, provider: provider)
  end

  def answer(fixture = "stedi_271_dependent")
    source, = stedi_answering(fixture.is_a?(String) ? canned(fixture) : answering(JSON.dump(fixture)))
    source.eligibility(inquiry)
  end

  def edited(fixture = "stedi_271_dependent")
    JSON.parse(File.read(File.join(CannedSource::FIXTURES, "#{fixture}.json"))).tap { yield(_1) }
  end

  describe "the inquiry" do
    it "asks about the dependent" do
      expect(inquiry.patient).to be(patient)
      expect(inquiry).to be_dependent
    end

    it "takes the member id from the subscriber and the rest from the dependent" do
      expect(inquiry.satisfies?([%i[member_id first_name last_name date_of_birth]])).to be(true)
    end

    it "does not take the dependent's names from the subscriber" do
      expect(inquiry(dependent: EdiGem::Subscriber.new(first_name: "Testfirst"))
               .satisfies?([%i[member_id last_name]])).to be(false)
    end

    it "is refused on a discovery, which cannot carry a dependent" do
      expect do
        EdiGem::Inquiry::Discovery.new(subscriber: patient, dependent: patient, provider: provider,
                                       as_of: "20260901")
      end.to raise_error(ArgumentError, /dependent/)
    end
  end

  describe "the Stedi body" do
    subject(:body) { EdiGem::Source::Stedi.new(api_key: "test_key").eligibility_body(inquiry) }

    it "sends the policy's member id alone on the subscriber" do
      expect(body[:subscriber]).to eq(memberId: "MOCK00000002")
    end

    it "sends the patient as the one dependent, plain, with the relationship" do
      expect(body[:dependents]).to eq([{ firstName: "TESTFIRST", lastName: "TESTLAST",
                                         dateOfBirth: "20100101",
                                         individualRelationshipCode: "19" }])
    end

    it "sends the dependent's suffix in its own field" do
      junior = EdiGem::Subscriber.new(first_name: "Testfirst", last_name: "Testlast Jr", relationship: :child)
      sent = EdiGem::Source::Stedi.new(api_key: "test_key").eligibility_body(inquiry(dependent: junior))

      expect(sent[:dependents].first).to include(lastName: "TESTLAST", suffix: "JR")
    end

    it "leaves the relationship out when it is not known" do
      unknown = EdiGem::Subscriber.new(first_name: "Testfirst", relationship: nil)
      sent = EdiGem::Source::Stedi.new(api_key: "test_key").eligibility_body(inquiry(dependent: unknown))

      expect(sent[:dependents].first).to_not have_key(:individualRelationshipCode)
    end

    it "sends no dependents when the patient is the subscriber" do
      expect(EdiGem::Source::Stedi.new(api_key: "test_key").eligibility_body(inquiry(dependent: nil)))
        .to_not have_key(:dependents)
    end
  end

  describe "the 270" do
    subject(:segments) do
      EdiGem::X12::Transaction270.new(inquiry, payer_code: "77027", trace: "1234567890").segments
    end

    it "gives the subscriber level a child, and writes only the policy under it" do
      expect(segments).to include("HL*3*2*22*1~", "NM1*IL*1******MI*MOCK00000002~")
    end

    it "writes the patient at the dependent level with the trace, relationship and service types" do
      at = segments.index("HL*4*3*23*0~")

      expect(segments[at + 1, 5]).to eq(["TRN*1*1234567890*1234567890~",
                                         "NM1*03*1*TESTLAST*TESTFIRST~",
                                         "DMG*D8*20100101~", "INS*N*19~", "EQ*30~"])
    end

    it "puts the trace on the patient only" do
      expect(segments.count { _1.start_with?("TRN*") }).to eq(1)
    end
  end

  describe "the answer, read" do
    it "names the subscriber and the dependent apart" do
      response = answer

      expect(response.subscriber_person.relationship_code).to eq("18")
      expect(response.dependent_people.map(&:relationship_code)).to eq(["19"])
    end

    it "reads a suffix the payer sends apart as part of the last name" do
      suffixed = edited { |body| body["dependents"].first["suffix"] = "JR" }

      expect(answer(suffixed).dependent_people.first.last_name).to eq("TESTLAST JR")
    end

    it "reads the payer's correction codes on the dependent" do
      expect(answer.dependent_people.first).to be_identity_corrected
    end

    it "still reads the member id off the subscriber for every line" do
      expect(answer.benefits.map(&:member_id).uniq).to eq(["MOCK00000002"])
    end

    it "reads a dependent's refusal in its own lane" do
      refused = edited do |body|
        body["dependents"].first["aaaErrors"] = [{ "code" => "65", "description" => "x" }]
      end

      expect(answer(refused).rejections_at(:dependent).map(&:code)).to eq([:name_mismatch])
    end

    # The payer ignored the dependent: nobody in the dependent part, only the subscriber.
    it "reads only the subscriber when the payer answered about them instead" do
      ignored = answer(edited { |body| body.delete("dependents") })

      expect([ignored.dependent_people, ignored.subscriber_person.relationship_code]).to eq([[], "18"])
    end

    it "reads no person from a subscriber part that holds only a refusal" do
      refused = edited do |body|
        body.delete("dependents")
        body["subscriber"] = { "aaaErrors" => [{ "code" => "72" }] }
      end

      expect(answer(refused).people).to eq([])
    end

    it "reads nobody when the answer names no one" do
      nobody = edited do |body|
        body.delete("dependents")
        body.delete("subscriber")
      end

      expect([answer(nobody).people, answer(nobody).subscriber_person]).to eq([[], nil])
    end
  end

  describe "a 271 with the patient at the dependent level" do
    def reading(*segments)
      body = x12_271("GS*HB*SENDER*RECEIVER*20260903*1200*1*X*005010X279A1~",
                     "ST*271*0001~", "HL*1**20*1~", "NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*38333~",
                     "HL*2*1*21*1~", "NM1*1P*2*EXAMPLECLINIC*****XX*1999999984~",
                     "HL*3*2*22*1~", "NM1*IL*1*HOLDER*POLICY****MI*MOCK00000002~",
                     "DMG*D8*19700101~", "INS*Y*18~",
                     "HL*4*3*23*0~", "NM1*03*1*TESTLAST*TESTFIRST~", "DMG*D8*20100101~",
                     "INS*N*19*001*25~", *segments, "SE*15*0001~", "GE*1*1~", "IEA*1*000000001~")
      EdiGem::Reading.new(document: EdiGem::Payload.new(body: body, dialect: :x12).document,
                          schema: EdiGem::Schema.fetch(:x12_271))
    end

    it "reads the subscriber and the dependent as two people" do
      people = reading.people

      expect(people.map(&:role)).to eq(%i[subscriber dependent])
      expect([people.last.first_name, people.last.last_name, people.last.date_of_birth])
        .to eq(%w[TESTFIRST TESTLAST 20100101])
      expect(people.last).to be_identity_corrected
    end

    it "reads the dependent's lines and dates, under the subscriber's member id" do
      benefits = reading("DTP*356*D8*20250101~", "EB*1**30~").benefits

      expect(benefits.map { [_1.status, _1.member_id, _1.begins_on] })
        .to eq([[:active, "MOCK00000002", "20250101"]])
    end

    it "reads a refusal at the dependent level in the dependent lane" do
      expect(reading("AAA*Y**71*C~").rejections.map { [_1.level, _1.code] })
        .to eq([%i[dependent date_of_birth_mismatch]])
    end

    it "reads the dependent's end date" do
      expect(reading("DTP*357*D8*20261231~", "EB*1**30~").benefits.map(&:ends_on)).to eq(["20261231"])
    end
  end

  describe "a discovery that found the patient as a dependent" do
    it "reads the relationship of the person matched" do
      source, = stedi_answering(canned("stedi_discovery_dependent"))
      found = source.discovery(EdiGem::Inquiry::Discovery.new(subscriber: patient, provider: provider,
                                                              as_of: "20260901"))

      expect(found.found_plans.map { |plan| plan.person.relationship_code }).to eq(["19"])
    end
  end
end
