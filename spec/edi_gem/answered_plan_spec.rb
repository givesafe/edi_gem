# frozen_string_literal: true

# The role a check's answer and each discovered plan both play. Every value here is made up.
RSpec.describe EdiGem::AnsweredPlan do
  let(:day) { Date.new(2026, 6, 1) }
  let(:held) { { first_name: "TESTFIRST", last_name: "TESTLAST", date_of_birth: "19800101" } }
  let(:asked) { { first_name: "Testfirst", last_name: "Testlast", date_of_birth: Date.new(1980, 1, 1) } }
  let(:benefits) do
    [EdiGem::Benefit.new(status: :active, service_types: ["30"], insurance_type: "MC", member_id: "MOCKID0002",
                         payer_code: "P1", plan_name: "EXAMPLE PLAN", plan_number: "PLAN01",
                         group_number: "GRP01", state_insurance_id: "MEDID0001"),
     EdiGem::Benefit.new(benefit_type: :co_payment, service_types: %w[98 UC], in_network: true)]
  end
  let(:person) { EdiGem::Person.new(role: :subscriber, relationship_code: "18", **held) }

  let(:other) { EdiGem::Person.new(role: :subscriber, relationship_code: "18", **held, first_name: "OTHER") }
  let(:dependent) { EdiGem::Person.new(role: :dependent, relationship_code: "19", **held) }

  # The payer refused the birth date it was sent (AAA 71).
  let(:refusal) { [EdiGem::Rejection.new(level: :subscriber, code: :date_of_birth_mismatch)] }

  # Each host builds `plan` from `answer(benefits:, people:, rejections:)`.
  # rubocop:todo RSpec/MultipleMemoizedHelpers -- over the gem's limit; whether to split it or raise the limit is Danny's call
  shared_examples "an answered plan" do
    # rubocop:enable RSpec/MultipleMemoizedHelpers
    let(:plan) { answer(benefits: benefits, people: [person]) }

    it "answers the payer, the IDs and the plan's names in the same words" do
      expect([plan.payer_code, plan.member_id, plan.medicaid_id, plan.plan_name, plan.plan_number, plan.group_number])
        .to eq(["P1", "MOCKID0002", "MEDID0001", "EXAMPLE PLAN", "PLAN01", "GRP01"])
    end

    it "says the plan is active on the day" do
      expect(plan.status_on(day)).to eq :active
    end

    it "names the person as the policyholder" do
      expect(plan.relationship).to eq :self
    end

    it "compares who the payer answered about with who was asked" do
      expect(plan.identification).to be_matched
    end

    it "gives the lines to keep, each in the shared words" do
      expect(plan.lines.map(&:to_h))
        .to eq([{ benefit_type: :active, service_types: ["30"], insurance_type: "MC", plan_name: "EXAMPLE PLAN",
                  in_network: nil },
                { benefit_type: :co_payment, service_types: %w[98 UC], insurance_type: nil, plan_name: nil,
                  in_network: true }])
    end

    it "is mismatched WHEN the payer answered about someone else, and the plan's status is still its own" do
      plan = answer(benefits: benefits, people: [other])

      expect([plan.identification.match, plan.status_on(day), plan.relationship]).to eq(%i[mismatched active self])
    end

    it "is the dependent WHEN the payer matched the person as one" do
      plan = answer(benefits: benefits, people: [other, dependent])

      expect([plan.relationship, plan.identification.match]).to eq(%i[dependent matched])
    end

    it "has no relationship WHEN the payer named nobody, and compares nothing" do
      plan = answer(benefits: benefits, people: [])

      expect([plan.relationship, plan.identification.match]).to eq([nil, :not_compared])
    end

    it "is inactive WHEN the plan's line says so" do
      expect(answer(benefits: [EdiGem::Benefit.new(status: :inactive)], people: [person]).status_on(day))
        .to eq :inactive
    end

    it "is unknown WHEN no line on the plan says active or inactive, never inactive" do
      expect(answer(benefits: [EdiGem::Benefit.new(benefit_type: :co_payment)], people: [person]).status_on(day))
        .to eq :unknown
    end

    it "has no lines, no fields and an unknown status WHEN the payer sent no benefits" do
      plan = answer(benefits: [], people: [person])

      expect([plan.lines, plan.status_on(day), *fields(plan)]).to eq([[], :unknown] + ([nil] * 6))
    end

    it "gives the plan's own dates as Dates" do
      dated = answer(benefits: [EdiGem::Benefit.new(status: :active, plan_begins_on: "20260101",
                                                    plan_ends_on: "20261231")], people: [person])

      expect([dated.plan_begins_on, dated.plan_ends_on]).to eq([Date.new(2026, 1, 1), Date.new(2026, 12, 31)])
    end

    { "nil" => nil, "an eight-digit number" => 20_260_101, "a string that isn't YYYYMMDD" => "2026-01-01",
      "eight digits that aren't a day" => "20261340" }.each do |kind, value|
      it "has no plan dates WHEN the answer holds #{kind}" do
        dated = answer(benefits: [EdiGem::Benefit.new(status: :active, plan_begins_on: value, plan_ends_on: value)],
                       people: [person])

        expect([dated.plan_begins_on, dated.plan_ends_on]).to eq([nil, nil])
      end
    end

    it "has nil fields WHEN the lines name none" do
      expect(fields(answer(benefits: [EdiGem::Benefit.new(status: :active)], people: [person]))).to eq([nil] * 6)
    end
  end

  def fields(plan)
    [plan.payer_code, plan.member_id, plan.medicaid_id, plan.plan_name, plan.plan_number, plan.group_number]
  end

  describe EdiGem::CheckedPlan do
    def answer(benefits:, people:, rejections: [])
      response = EdiGem::Response.new(benefits: benefits, people: people, rejections: rejections)
      response.checked_plan(identification: response.identify(asked))
    end

    it_behaves_like "an answered plan"

    it "carries the payer's refusal of the person, with no relationship, the plan's status its own" do
      plan = answer(benefits: benefits, people: [person], rejections: refusal)

      expect([plan.identification.match, plan.identification.reason, plan.relationship, plan.status_on(day)])
        .to eq([:mismatched, :date_of_birth_mismatch, nil, :active])
    end
  end

  describe EdiGem::MedicalPlan do
    def answer(benefits:, people:, rejections: [])
      found = EdiGem::FoundPlan.new(benefits: benefits, people: people)
      EdiGem::Response.new(found_plans: [found], rejections: rejections)
                      .medical_plans(asked: EdiGem::Person::Asked.new(**asked)).fetch(0)
    end

    it_behaves_like "an answered plan"

    it "never carries a refusal: a discovery's refusals are about the whole answer" do
      plan = answer(benefits: benefits, people: [person], rejections: refusal)

      expect([plan.identification.match, plan.identification.refusal, plan.relationship]).to eq([:matched, nil, :self])
    end
  end

  # As InsuranceCoverageBenefit.replace_for keeps them.
  # rubocop:todo RSpec/MultipleMemoizedHelpers -- over the gem's limit; whether to split it or raise the limit is Danny's call
  describe EdiGem::AnsweredPlan::Line do
    # rubocop:enable RSpec/MultipleMemoizedHelpers
    let(:lines) do
      described_class.all([EdiGem::Benefit.new(status: :active, service_types: ["30"], insurance_type: "MC"),
                           EdiGem::Benefit.new(benefit_type: :co_payment, service_types: %w[98 UC], in_network: true),
                           EdiGem::Benefit.new(plan_name: "EXAMPLE PLAN")])
    end

    it "keeps each line, and not the plan around them" do
      expect(lines.map { |line| [line.benefit_type, line.service_types, line.insurance_type, line.in_network] })
        .to eq([[:active, ["30"], "MC", nil], [:co_payment, %w[98 UC], nil, true]])
    end

    it "keeps a line that names no service type with none" do
      expect(described_class.all([EdiGem::Benefit.new(status: :inactive)]).map(&:service_types)).to eq([[]])
    end

    it "names a status line's status as what it says" do
      expect(described_class.all([EdiGem::Benefit.new(status: :non_covered)]).map(&:benefit_type))
        .to eq([:non_covered])
    end
  end
end
