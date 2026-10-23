# frozen_string_literal: true

RSpec.describe EdiGem::Identification do
  let(:asked) { { first_name: "José", last_name: "Núñez", date_of_birth: Date.new(1980, 1, 1) } }

  def person(role = :subscriber, first_name: "JOSE", last_name: "NUNEZ", date_of_birth: "19800101")
    EdiGem::Person.new(role: role, first_name: first_name, last_name: last_name, date_of_birth: date_of_birth)
  end

  def response(people: [], rejections: [])
    EdiGem::Response.new(people: people, rejections: rejections)
  end

  def rejection(level, code)
    EdiGem::Rejection.new(level: level, code: code)
  end

  describe "Response#identify" do
    let(:found) { answer.identify(asked, as_dependent: false) }

    context "WHEN the payer answered about the person in its own spelling" do
      let(:answer) { response(people: [person]) }

      it "is matched, answered as the subscriber" do
        expect(found).to have_attributes(match: :matched, matched?: true, reason: nil, answered_as: :subscriber)
      end

      it "has each field matched and the member ID not compared" do
        expect(found.fields).to eq(first_name: :matched, last_name: :matched, date_of_birth: :matched,
                                   member_id: :not_returned)
      end
    end

    context "WHEN the payer answered about someone else on the ID" do
      let(:answer) { response(people: [person(first_name: "MARIA", date_of_birth: "19820505")]) }

      it "is mismatched" do
        expect(found).to have_attributes(match: :mismatched, mismatched?: true, reason: :identity_mismatch,
                                         answered_as: :subscriber)
      end

      it "names only which fields differ" do
        expect(found.differing).to eq(%i[first_name date_of_birth])
      end
    end

    context "WHEN the payer sent no birth date" do
      let(:answer) { response(people: [person(date_of_birth: nil)]) }

      it "is not_compared, never matched" do
        expect([found.match, found.fields[:date_of_birth]]).to eq(%i[not_compared not_returned])
      end
    end

    context "WHEN the payer moved the person into the dependent part" do
      let(:answer) { response(people: [person(first_name: "ANA", date_of_birth: "19500303"), person(:dependent)]) }

      it "is matched, answered as a dependent" do
        expect(found).to have_attributes(match: :matched, answered_as: :dependent)
      end
    end

    context "WHEN the answer named nobody" do
      let(:answer) { response }

      it "is not_compared, answered as nobody" do
        expect(found).to have_attributes(match: :not_compared, answered_as: nil)
      end
    end

    context "WHEN the payer found the ID but not the birth date (AAA 71)" do
      let(:answer) { response(people: [person], rejections: [rejection(:subscriber, :date_of_birth_mismatch)]) }

      it "is mismatched by the payer's code, which wins over our comparison" do
        expect(found).to have_attributes(match: :mismatched, reason: :date_of_birth_mismatch, answered_as: nil)
      end

      it "names the birth date only" do
        expect(found.fields).to eq(first_name: :not_returned, last_name: :not_returned, date_of_birth: :differs,
                                   member_id: :not_returned)
      end

      it "keeps our own comparison for whoever reads it" do
        expect(found.result).to be_matched
      end
    end

    context "WHEN the payer found the ID but not the dependent's name (AAA 65)" do
      let(:answer) { response(rejections: [rejection(:dependent, :name_mismatch)]) }

      it "is mismatched for both names" do
        expect(found).to have_attributes(match: :mismatched, reason: :name_mismatch,
                                         differing: %i[first_name last_name])
      end
    end

    context "WHEN the payer did not find the ID (AAA 72)" do
      let(:answer) { response(rejections: [rejection(:subscriber, :member_id_invalid)]) }

      it "is not_compared, since the ID may not be theirs, and names the ID" do
        expect(found).to have_attributes(match: :not_compared, reason: :member_id_invalid, differing: [:member_id])
      end
    end

    context "WHEN the payer found nobody (AAA 75)" do
      let(:answer) { response(rejections: [rejection(:subscriber, :subscriber_not_found)]) }

      it "is not_compared, not found, and names no field" do
        expect(found).to have_attributes(match: :not_compared, reason: :not_found, differing: [])
      end
    end

    context "WHEN the patient was found at neither level (AAA 77)" do
      let(:answer) { response(rejections: [rejection(:dependent, :patient_not_found)]) }

      it("is not found") { expect(found.reason).to eq(:not_found) }
    end

    context "WHEN the refusal is about the provider" do
      let(:answer) { response(people: [person], rejections: [rejection(:provider, :provider_not_enrolled_on_date)]) }

      it("compares the person instead") { expect(found.match).to eq(:matched) }
    end

    context "WHEN a person's code came back in the provider lane" do
      let(:answer) { response(people: [person], rejections: [rejection(:provider, :name_mismatch)]) }

      it("is no refusal about the person") { expect(found.refusal).to be_nil }
    end

    it "takes whoever answers to_h as the person asked about" do
      asked_person = Struct.new(:first_name, :last_name, :date_of_birth, keyword_init: true).new(**asked)

      expect(response(people: [person]).identify(asked_person)).to be_matched
    end
  end

  describe "FoundPlan#identify" do
    def plan(*people)
      EdiGem::FoundPlan.new(benefits: [], people: people)
    end

    it "is matched WHEN the plan names the person in the payer's spelling, with no member ID compared" do
      expect(plan(person).identify(asked))
        .to have_attributes(match: :matched, reason: nil, answered_as: :subscriber,
                            fields: { first_name: :matched, last_name: :matched, date_of_birth: :matched })
    end

    it "is matched on the dependent WHEN the plan names the person as one" do
      expect(plan(person(first_name: "ANA"), person(:dependent)).identify(asked))
        .to have_attributes(match: :matched, answered_as: :dependent)
    end

    it "is mismatched WHEN the plan names someone else" do
      expect(plan(person(date_of_birth: "19820505")).identify(asked))
        .to have_attributes(match: :mismatched, reason: :identity_mismatch)
    end

    it "is not_compared WHEN the plan names nobody" do
      expect(plan.identify(asked)).to have_attributes(match: :not_compared, answered_as: nil)
    end
  end

  describe "#given_fields" do
    it "is empty for a check's question, which carries no address or SSN" do
      expect(response(people: [person]).identify(asked).given_fields).to eq({})
    end

    it "is empty WHEN made without them" do
      expect(described_class.new(person: person, result: nil).given_fields).to eq({})
    end

    it "hands up the findings it was given, beside a core result they never change" do
      found = described_class.of(person(date_of_birth: "19800102"), asked, given_fields: { address: :matched })

      expect([found.given_fields, found.match, found.differing])
        .to eq([{ address: :matched }, :mismatched, %i[date_of_birth]])
    end
  end
end
