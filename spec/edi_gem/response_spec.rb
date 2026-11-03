# frozen_string_literal: true

RSpec.describe EdiGem::Response do
  def rejection(level, code = nil)
    EdiGem::Rejection.new(level: level, code: code)
  end

  def benefit(status)
    EdiGem::Benefit.new(status: status)
  end

  describe "#state" do
    it "is complete when the payer answered with coverage" do
      expect(described_class.new(benefits: [benefit(:active)]).state).to eq(:complete)
    end

    it "is no_coverage when the payer answered and reported none" do
      expect(described_class.new.state).to eq(:no_coverage)
    end

    it "is not_identified when the subscriber could not be matched" do
      response = described_class.new(rejections: [rejection(:subscriber, :member_id_invalid)])

      expect(response.state).to eq(:not_identified)
    end

    it "is rejected when the payer needs another identifier for a dependent, which Stedi says is ours to send" do
      response = described_class.new(rejections: [rejection(:dependent, :dependent_id_required)])

      expect(response.state).to eq(:rejected)
    end

    it "is payer_silent when the payer itself refused to answer" do
      response = described_class.new(rejections: [rejection(:payer, :payer_unavailable)])

      expect(response.state).to eq(:payer_silent)
    end

    it "is rejected when our own standing with the payer was the problem" do
      response = described_class.new(rejections: [rejection(:provider, :provider_not_on_file)])

      expect(response.state).to eq(:rejected)
    end

    # A provider reason (AAA 45) can arrive in the subscriber loop.
    it "is rejected when a provider reason came back in the subscriber lane" do
      response = described_class.new(rejections: [rejection(:subscriber, :provider_not_eligible)])

      expect(response.state).to eq(:rejected)
    end

    it "is rejected when the envelope refused the request before a payer saw it" do
      expect(described_class.new(rejections: [rejection(:envelope)]).state).to eq(:rejected)
    end

    describe "an answer that echoed the member and payer and sent no benefit line" do
      let(:echoed) { EdiGem::Benefit.new(member_id: "M1", payer_code: "KYMCD") }

      it "is payer_silent WHEN a refusal came with it that says nothing of the person or our request" do
        response = described_class.new(benefits: [echoed], rejections: [rejection(:subscriber, "AA")])

        expect(response.state).to eq(:payer_silent)
      end

      it "is rejected WHEN the refusal is about what we sent" do
        response = described_class.new(benefits: [echoed],
                                       rejections: [rejection(:subscriber, :required_data_missing)])

        expect(response.state).to eq(:rejected)
      end

      it "is no_coverage WHEN the refusal says the person died before the day asked" do
        response = described_class.new(benefits: [echoed],
                                       rejections: [rejection(:subscriber, :date_of_death_conflict)])

        expect(response.state).to eq(:no_coverage)
      end

      it "is no_coverage WHEN nothing was refused" do
        expect(described_class.new(benefits: [echoed]).state).to eq(:no_coverage)
      end

      it "is complete WHEN the same answer also sent a line describing a term of the plan" do
        term = EdiGem::Benefit.new(benefit_type: :deductible)

        expect(described_class.new(benefits: [echoed, term]).state).to eq(:complete)
      end
    end

    it "is pending when an asynchronous source has answered only with a handle" do
      expect(described_class.new(handle: "abc123").state).to eq(:pending)
    end

    describe "an answer with benefit lines and a refusal beside them" do
      it "is partial WHEN the refusal is about part of what was asked" do
        response = described_class.new(benefits: [benefit(:active)],
                                       rejections: [rejection(:subscriber, :date_out_of_range)])

        expect(response.state).to eq(:partial)
      end

      it "is not_identified WHEN the refusal says the member was not found" do
        response = described_class.new(benefits: [benefit(:active)],
                                       rejections: [rejection(:subscriber, :subscriber_not_found)])

        expect(response.state).to eq(:not_identified)
      end

      it "is rejected WHEN the refusal is about our standing" do
        response = described_class.new(benefits: [benefit(:active)],
                                       rejections: [rejection(:provider, :provider_not_on_file)])

        expect(response.state).to eq(:rejected)
      end
    end

    it "prefers an explicitly declared state over a derived one" do
      response = described_class.new(benefits: [benefit(:active)], state: :partial)

      expect(response.state).to eq(:partial)
    end
  end

  describe "#payer_unavailable? and #ask_again?" do
    def payer_down(followup)
      EdiGem::Rejection.new(level: :payer, code: :payer_unavailable, reason_code: "42",
                            followup: followup)
    end

    it "says the payer can't answer right now, and to ask again, WHEN the payer lane says 42 with no bar" do
      response = described_class.new(rejections: [payer_down(nil)])

      expect([response.payer_unavailable?, response.ask_again?]).to eq([true, true])
    end

    # Stedi: a 42 with C, N or S is a problem with the request, for Stedi support.
    it "says the payer refused the request as sent, not that it is down, WHEN the 42's follow-up is N" do
      response = described_class.new(rejections: [payer_down("Resubmission Not Allowed")])

      expect([response.payer_unavailable?, response.ask_again?, response.resubmission_refused?])
        .to eq([false, false, true])
    end

    it "says the payer is down, not that it refused the request, WHEN the 42 has no bar" do
      expect(described_class.new(rejections: [payer_down(nil)]).resubmission_refused?).to be(false)
    end

    it "says an 80 is never refused as sent, whatever its follow-up" do
      eighty = EdiGem::Rejection.new(level: :payer, code: :payer_unavailable, reason_code: "80", followup: "N")

      expect(described_class.new(rejections: [eighty]).resubmission_refused?).to be(false)
    end

    it "says the payer couldn't be reached, and not to ask again, WHEN the payer lane says 79 alone" do
      response = described_class.new(rejections: [rejection(:payer, :invalid_participant)])

      expect([response.payer_unavailable?, response.ask_again?]).to eq([true, false])
    end

    it "says to ask again WHEN a 42 Stedi would ask again comes beside a 79" do
      response = described_class.new(rejections: [rejection(:payer, :invalid_participant), payer_down(nil)])

      expect([response.payer_unavailable?, response.ask_again?]).to eq([true, true])
    end

    it "says to ask again WHEN the payer lane says 80, whatever its follow-up" do
      eighty = EdiGem::Rejection.new(level: :payer, code: :payer_unavailable, reason_code: "80",
                                     followup: "Resubmission Not Allowed")
      response = described_class.new(rejections: [eighty])

      expect([response.payer_unavailable?, response.ask_again?]).to eq([true, true])
    end

    # Stedi's eligibility troubleshooting page lists 79 in its provider table as "a problem
    # connecting with this payer", and says not to ask a 79 again on its own.
    it "says the payer couldn't be reached, and our standing not connected, WHEN the provider lane says 79" do
      response = described_class.new(rejections: [rejection(:provider, :invalid_participant)])

      expect([response.payer_unavailable?, response.ask_again?, response.provider_standing, response.state])
        .to eq([true, false, :not_connected, :payer_silent])
    end

    it "says to ask again WHEN the provider lane says 42 with no bar" do
      down = EdiGem::Rejection.new(level: :provider, code: :payer_unavailable, reason_code: "42")
      response = described_class.new(rejections: [down])

      expect([response.payer_unavailable?, response.ask_again?, response.provider_standing])
        .to eq([true, true, nil])
    end

    it "says the request was refused as sent WHEN the provider lane says 42 with follow-up C" do
      refused = EdiGem::Rejection.new(level: :provider, code: :payer_unavailable, reason_code: "42", followup: "C")
      response = described_class.new(rejections: [refused])

      expect([response.resubmission_refused?, response.payer_unavailable?, response.ask_again?,
              response.deciding_rejection]).to eq([true, false, false, refused])
    end

    it "says our provider was refused WHEN the provider lane says 43 or 41" do
      responses = %i[provider_not_on_file authorization_restricted].map do |code|
        described_class.new(rejections: [rejection(:provider, code)])
      end

      expect(responses.map { |response| [response.provider_standing, response.payer_unavailable?, response.state] })
        .to eq([[:refused, false, :rejected]] * 2)
    end

    # Stedi's subscriber and dependent tables give 42 the payer table's resolution: "The payer can't
    # respond to your request", or with follow-up C, N or S "There is a problem with your request".
    it "says the payer can't answer right now, and to ask again, WHEN the person's lane says 42 with no bar" do
      responses = %i[subscriber dependent].map do |level|
        down = EdiGem::Rejection.new(level: level, code: :payer_unavailable, reason_code: "42")
        described_class.new(benefits: [benefit(:active)], rejections: [down])
      end

      expect(responses.map { |response| [response.payer_unavailable?, response.ask_again?, response.state] })
        .to eq([[true, true, :payer_silent]] * 2)
    end

    it "says the request was refused as sent, and not to ask again, WHEN the person's lane says 42 with follow-up S" do
      refused = EdiGem::Rejection.new(level: :subscriber, code: :payer_unavailable, reason_code: "42", followup: "S")
      response = described_class.new(rejections: [rejection(:subscriber, :gender_missing), refused])

      expect([response.resubmission_refused?, response.ask_again?, response.deciding_rejection])
        .to eq([true, false, refused])
    end

    it "says neither WHEN the refusal is another, or in another lane" do
      responses = [described_class.new(rejections: [rejection(:subscriber, :subscriber_not_found)]),
                   described_class.new(rejections: [rejection(:subscriber, :invalid_participant)]),
                   described_class.new]

      expect(responses.map { |response| [response.payer_unavailable?, response.ask_again?] })
        .to eq([[false, false]] * 3)
    end
  end

  describe "#deciding_rejection" do
    def deciding(*rejections, benefits: [])
      described_class.new(benefits: benefits, rejections: rejections).deciding_rejection
    end

    it "is the person's refusal the state read, not a refusal listed ahead of it that decides nothing" do
      required = rejection(:subscriber, :required_data_missing)

      expect(deciding(rejection(:subscriber, :gender_missing), required)).to be(required)
    end

    it "is a refusal of our provider ahead of one of the request" do
      provider = rejection(:provider, :provider_not_on_file)

      expect(deciding(rejection(:envelope, "AAA"), provider)).to be(provider)
    end

    it "is the refusal of the request when no provider was refused" do
      envelope = rejection(:envelope, "AAA")

      expect(deciding(rejection(:subscriber, :required_data_missing), envelope)).to be(envelope)
    end

    it "is the person's refusal when the payer can't tell who they are, ahead of the payer's" do
      not_found = rejection(:subscriber, :subscriber_not_found)

      expect(deciding(rejection(:payer, :payer_unavailable), not_found)).to be(not_found)
    end

    it "is the payer's refusal of the request as sent ahead of one that is only down" do
      refused = EdiGem::Rejection.new(level: :payer, code: :payer_unavailable, reason_code: "42", followup: "C")

      expect(deciding(rejection(:payer, :payer_unavailable), refused)).to be(refused)
    end

    it "is the payer's refusal of our setup ahead of one that is only down" do
      setup = rejection(:payer, :payer_identifier_missing)

      expect(deciding(rejection(:payer, :payer_unavailable), setup)).to be(setup)
    end

    it "is the payer that couldn't be reached ahead of another payer refusal" do
      down = rejection(:payer, :payer_unavailable)

      expect(deciding(rejection(:payer, "99"), down)).to be(down)
    end

    it "is the payer's first refusal when none of them says more" do
      first = rejection(:payer, "99")

      expect(deciding(first, rejection(:payer, "98"))).to be(first)
    end

    it "is the payer's refusal ahead of the person's our-fault one, as the state reads it" do
      payer = rejection(:payer, "99")

      expect(deciding(rejection(:subscriber, :required_data_missing), payer)).to be(payer)
    end

    it "is the first refusal when no lane reads any" do
      first = rejection(:subscriber, :gender_missing)

      expect(deciding(first, rejection(:dependent, :gender_missing), benefits: [benefit(:active)])).to be(first)
    end

    it "is nil when nothing was refused" do
      expect(deciding).to be_nil
    end
  end

  describe "#error_summary" do
    it "is the deciding refusal in codes alone" do
      refused = EdiGem::Rejection.new(level: :subscriber, code: :date_out_of_range, reason_code: "62",
                                      description: "free text", resolution: "free text")

      expect(described_class.new(rejections: [rejection(:subscriber, :gender_missing), refused]).error_summary)
        .to eq("AAA 62 at subscriber")
    end

    it "is nil when nothing was refused" do
      expect(described_class.new.error_summary).to be_nil
    end
  end

  describe "#our_setup_refused?" do
    it "is a 41 or a T4 in the payer lane" do
      responses = %i[authorization_restricted payer_identifier_missing].map do |code|
        described_class.new(rejections: [rejection(:payer, code)])
      end

      expect(responses.map { |response| [response.our_setup_refused?, response.state] })
        .to eq([[true, :payer_silent]] * 2)
    end

    # Stedi's provider table: a T4 is the tradingPartnerName or tradingPartnerServiceId we sent, or a
    # payer processing issue, not our provider.
    it "is a T4 in the provider's lane, which leaves our provider's standing alone" do
      response = described_class.new(rejections: [rejection(:provider, :payer_identifier_missing)])

      expect([response.our_setup_refused?, response.state, response.provider_standing, response.deciding_rejection])
        .to eq([true, :payer_silent, nil, response.rejections.first])
    end

    it "is not a 41 in the provider's lane, which refuses our provider" do
      response = described_class.new(rejections: [rejection(:provider, :authorization_restricted)])

      expect([response.our_setup_refused?, response.state]).to eq([false, :rejected])
    end

    it "is not a payer that is down" do
      expect(described_class.new(rejections: [rejection(:payer, :payer_unavailable)])).to_not be_our_setup_refused
    end
  end

  describe "#error_code" do
    it "is the deciding refusal's code, not the first one listed" do
      response = described_class.new(rejections: [rejection(:subscriber, :gender_missing),
                                                  rejection(:subscriber, :required_data_missing)])

      expect(response.error_code).to eq("required_data_missing")
    end

    it "is nil when nothing was refused" do
      expect(described_class.new.error_code).to be_nil
    end

    it "is a code the codec did not name as its raw string" do
      expect(described_class.new(rejections: [rejection(:payer, "99")]).error_code).to eq("99")
    end
  end

  describe "#provider_refusals" do
    it "holds the refusals about our standing, from any lane" do
      in_subscriber_lane = rejection(:subscriber, :provider_not_on_file)
      response = described_class.new(rejections: [in_subscriber_lane, rejection(:subscriber, :name_mismatch)])

      expect(response.provider_refusals).to eq([in_subscriber_lane])
    end
  end

  describe "#provider_standing" do
    it "is refused when a refusal is about our provider, even beside benefit lines" do
      response = described_class.new(benefits: [benefit(:active)], rejections: [rejection(:provider)])

      expect(response.provider_standing).to eq(:refused)
    end

    it "is needs_provider_details when the payer refused our provider for want of our tax ID and address" do
      [rejection(:provider, :required_data_missing), rejection(:provider, :provider_address_invalid),
       rejection(:subscriber, :provider_address_invalid)].each do |wanting|
        expect(described_class.new(rejections: [wanting]).provider_standing).to eq(:needs_provider_details)
      end
    end

    it "is refused when another refusal of our provider comes beside the one asking for our details" do
      response = described_class.new(rejections: [rejection(:provider, :provider_address_invalid),
                                                  rejection(:provider, :provider_not_on_file)])

      expect(response.provider_standing).to eq(:refused)
    end

    it "is accepted when the payer answered with benefits" do
      expect(described_class.new(benefits: [benefit(:active)]).provider_standing).to eq(:accepted)
    end

    it "is not_connected when Stedi couldn't connect to the payer, a 79 alone" do
      expect(described_class.new(rejections: [rejection(:payer, :invalid_participant)]).provider_standing)
        .to eq(:not_connected)
    end

    it "is nil when a 79 comes beside a 42, which Stedi says to ask again" do
      response = described_class.new(rejections: [rejection(:payer, :invalid_participant),
                                                  rejection(:payer, :payer_unavailable)])

      expect([response.provider_standing, response.ask_again?]).to eq([nil, true])
    end

    it "is accepted when the payer answered for part of the question" do
      response = described_class.new(benefits: [benefit(:active)], rejections: [rejection(:subscriber)])

      expect(response.provider_standing).to eq(:accepted)
    end

    it "is accepted when the payer answered and found no coverage" do
      expect(described_class.new.provider_standing).to eq(:accepted)
    end

    it "is nil when the payer did not answer" do
      response = described_class.new(rejections: [rejection(:payer, :payer_unavailable)])

      expect(response.provider_standing).to be_nil
    end

    it "is accepted when the payer could not match the person: it looked them up for our provider" do
      response = described_class.new(rejections: [rejection(:subscriber, :member_id_invalid)])

      expect(response.provider_standing).to eq(:accepted)
    end

    it "is nil when the request was refused for a reason other than our provider" do
      response = described_class.new(rejections: [rejection(:envelope)])

      expect(response.provider_standing).to be_nil
    end

    it "is nil while an asynchronous answer has not arrived" do
      expect(described_class.new(handle: "discovery-1").provider_standing).to be_nil
    end
  end

  it "keeps the response body in the dialect it arrived in" do
    payload = EdiGem::Payload.new(body: covered_271, dialect: :x12)

    expect(described_class.new(payload: payload).payload.body).to eq(covered_271)
  end
end
