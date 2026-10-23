# frozen_string_literal: true

require "json"
require_relative "../support/plan_date_forms"

# The plan a check's answer is about, ported from the app's Eligibility::CoverageFromCheck and
# BatchPoll examples. Every value here is made up.
RSpec.describe EdiGem::CheckedPlan do
  let(:day) { Date.new(2026, 6, 1) }
  let(:asked) { { first_name: "Testfirst", last_name: "Testlast", date_of_birth: Date.new(1980, 1, 1) } }
  let(:held) { { first_name: "TESTFIRST", last_name: "TESTLAST", date_of_birth: "19800101" } }
  let(:benefits) { [EdiGem::Benefit.new(status: :active, benefit_type: nil, plan_name: "EXAMPLE PLAN")] }
  let(:people) { [] }
  let(:rejections) { [] }
  let(:response) { EdiGem::Response.new(benefits: benefits, people: people, rejections: rejections) }
  let(:plan) { response.checked_plan(identification: response.identify(asked)) }

  describe "the plan's name and number" do
    it "is the active line's" do
      expect(plan.plan_name).to eq "EXAMPLE PLAN"
    end

    it "is the active line's WHEN an earlier line names another plan" do
      benefits.unshift(EdiGem::Benefit.new(benefit_type: :co_payment, plan_name: "OTHER PLAN", plan_number: "P2"))
      benefits << EdiGem::Benefit.new(status: :active, plan_name: "LATER PLAN")

      expect([plan.plan_name, plan.plan_number]).to eq(["EXAMPLE PLAN", nil])
    end

    it "is the first line's WHEN no line is active, as for a plan active by an implied term" do
      benefits.replace([EdiGem::Benefit.new(benefit_type: :co_payment, service_types: ["30"], plan_name: "TERM PLAN",
                                            plan_number: "PLAN01"),
                        EdiGem::Benefit.new(benefit_type: :deductible, plan_name: "SECOND PLAN")])

      expect([plan.plan_name, plan.plan_number, plan.status_on(day)]).to eq(["TERM PLAN", "PLAN01", :active])
    end

    it "is nil WHEN the answer names no plan, so a caller can keep what it held" do
      benefits.replace([EdiGem::Benefit.new(status: :active, benefit_type: nil)])

      expect([plan.plan_name, plan.plan_number]).to eq([nil, nil])
    end

    it "is nil WHEN the payer sent no lines at all" do
      benefits.clear

      expect([plan.plan_name, plan.plan_number, plan.member_id, plan.lines]).to eq([nil, nil, nil, []])
    end
  end

  it "reads a field of the plan from the first benefit that holds it" do
    benefits << EdiGem::Benefit.new(benefit_type: :co_payment, member_id: "MOCKID0001", group_number: "GRP01")

    expect([plan.member_id, plan.group_number, plan.medicaid_id]).to eq(["MOCKID0001", "GRP01", nil])
  end

  describe "#relationship" do
    it "is nil WHEN the payer gave nobody to compare; the app's own fallback is the app's" do
      expect(plan.relationship).to be_nil
    end

    context "WHEN the payer answered about the person as a dependent" do
      let(:people) do
        [EdiGem::Person.new(role: :subscriber, first_name: "OTHER", last_name: "TESTLAST", date_of_birth: "19700101"),
         EdiGem::Person.new(role: :dependent, **held)]
      end

      it "is dependent, and the person matched" do
        expect([plan.relationship, plan.identification.match]).to eq(%i[dependent matched])
      end
    end

    context "WHEN the payer answered about the person as the policyholder" do
      let(:people) { [EdiGem::Person.new(role: :subscriber, **held)] }

      it "is self" do
        expect(plan.relationship).to eq :self
      end
    end
  end

  describe "#status_on" do
    it "is the plan's own lines on the day" do
      benefits.replace([EdiGem::Benefit.new(status: :inactive)])

      expect(plan.status_on(day)).to eq :inactive
    end

    it "is unknown WHEN the payer says only that the plan is not covered; the verdict says not_covered" do
      benefits.replace([EdiGem::Benefit.new(status: :non_covered)])

      expect([plan.status_on(day), plan.verdict(on: day)])
        .to eq(%i[unknown not_covered])
    end

    context "WHEN the answer is about someone else" do
      let(:people) { [EdiGem::Person.new(role: :subscriber, **held, first_name: "OTHER")] }

      it "is still the plan's, and the verdict is unanswered, never their coverage" do
        expect([plan.status_on(day), plan.verdict(on: day)])
          .to eq(%i[active unanswered])
      end
    end
  end

  describe "an answer read from Stedi" do
    let(:plan) do
      source, = stedi_answering(canned("stedi_271_active_coverage"))
      inquiry = EdiGem::Inquiry::Eligibility.new(
        payer_code: "77027", provider: EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC"),
        subscriber: EdiGem::Subscriber.new(member_id: "MOCK00000001", last_name: "Testlast")
      )
      source.eligibility(inquiry).checked_plan
    end

    it "reads the plan the payer named" do
      expect([plan.payer_code, plan.member_id.size, plan.plan_name, plan.plan_number, plan.group_number])
        .to eq(["77027", 12, "MEDICAID MANAGED CARE", "PLAN0001", "GRP0001"])
    end

    it "keeps every line" do
      expect(plan.lines.map(&:benefit_type)).to eq(%i[active co_payment])
    end

    it "prints none of the answer's values" do
      expect(plan.inspect).to_not include("MOCK")
    end
  end

  describe "the plan's own dates" do
    it "are Dates, whichever identification the plan is read with" do
      benefits << EdiGem::Benefit.new(plan_begins_on: "20260101", plan_ends_on: "20261231")

      expect([plan.plan_begins_on, plan.plan_ends_on, response.checked_plan.plan_begins_on])
        .to eq([Date.new(2026, 1, 1), Date.new(2026, 12, 31), Date.new(2026, 1, 1)])
    end

    it "are nil WHEN absent" do
      expect([plan.plan_begins_on, plan.plan_ends_on]).to eq([nil, nil])
    end

    # Stedi's answer of active coverage, with `dates` as its planDateInformation.
    def answer_dated(dates)
      body = JSON.parse(File.read(File.join(CannedSource::FIXTURES, "stedi_271_active_coverage.json")))
      canned_body(body.merge("planDateInformation" => dates))
    end

    PlanDateForms::ALL.each do |form, (dates, expected)|
      it "are read from a check's planDateInformation WHEN it holds #{form}" do
        source, = stedi_answering(answer_dated(dates))
        inquiry = EdiGem::Inquiry::Eligibility.new(
          payer_code: "FLMCD", provider: EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic"),
          subscriber: EdiGem::Subscriber.new(member_id: "MOCK00000001", last_name: "Testlast",
                                             date_of_birth: "19800101")
        )
        checked = source.eligibility(inquiry).checked_plan

        expect([checked.plan_begins_on, checked.plan_ends_on]).to eq(expected)
      end
    end
  end

  it "carries no given details, since a check sends no address or SSN" do
    expect(plan.identification.given_fields).to eq({})
  end
end
