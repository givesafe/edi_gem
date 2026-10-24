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

      it "is payer_silent WHEN a refusal came with it" do
        response = described_class.new(benefits: [echoed],
                                       rejections: [rejection(:subscriber, :required_data_missing)])

        expect(response.state).to eq(:payer_silent)
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

  describe "#error_code" do
    it "is the first refusal's code" do
      expect(described_class.new(rejections: [rejection(:payer, :payer_unavailable)]).error_code)
        .to eq("payer_unavailable")
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

    it "is accepted when the payer answered with benefits" do
      expect(described_class.new(benefits: [benefit(:active)]).provider_standing).to eq(:accepted)
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

    it "is nil when the payer could not match the person" do
      response = described_class.new(rejections: [rejection(:subscriber, :member_id_invalid)])

      expect(response.provider_standing).to be_nil
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
