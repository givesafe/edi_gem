# frozen_string_literal: true

require "json"
require_relative "../support/plan_date_forms"
require "pp"

RSpec.describe EdiGem::MedicalPlan do
  let(:as_of) { Date.new(2026, 6, 1) }
  let(:line) do
    { member_id: "MOCKID0002", payer_code: "P1", payer_name: "EXAMPLE PAYER", status: :active,
      plan_name: "EXAMPLE PLAN", plan_number: "PLAN01" }
  end
  let(:held) { { first_name: "TESTFIRST", last_name: "TESTLAST", date_of_birth: "19800101" } }
  let(:found) { [found_plan([line], held)] }
  let(:plans) { EdiGem::Response.new(found_plans: found).medical_plans }
  let(:plan) { plans.fetch(0) }

  def found_plan(lines, *people)
    EdiGem::FoundPlan.new(benefits: lines.map { |each| EdiGem::Benefit.new(each) },
                          people: people.compact.map { |fields| EdiGem::Person.new(role: :subscriber, **fields) })
  end

  describe "Response#medical_plans" do
    it "is one plan for each coverage found" do
      found << found_plan([line.merge(payer_code: "P2", member_id: "OTHER")], held)

      expect(plans.map(&:member_id)).to eq %w[MOCKID0002 OTHER]
    end

    it "keeps each coverage's lines on its own plan" do
      found << found_plan([line.merge(payer_code: "P2", member_id: "OTHER")], held)

      expect(plans.map { |each| each.benefits.map(&:member_id) }).to eq [["MOCKID0002"], ["OTHER"]]
    end

    it "is none for an answer that found nothing" do
      expect(EdiGem::Response.new.medical_plans).to be_empty
    end

    context "WHEN a plan covers only dental or vision" do
      let(:found) { [found_plan([line.merge(service_types: %w[35]), line.merge(service_types: %w[AL])], held)] }

      it "leaves it out" do
        expect(plans).to be_empty
      end
    end

    context "WHEN a plan covers dental and medical care" do
      let(:found) { [found_plan([line.merge(service_types: %w[35 30])], held)] }

      it "keeps it" do
        expect(plans.size).to eq 1
      end
    end
  end

  it "reads the plan's own fields" do
    expect([plan.payer_code, plan.member_id, plan[:plan_name], plan[:plan_number]])
      .to eq(["P1", "MOCKID0002", "EXAMPLE PLAN", "PLAN01"])
  end

  describe "#coverage_on" do
    def status_of(**fields)
      found.replace([found_plan([line.merge(fields)], held)])
      plan.coverage_on(as_of).status
    end

    it "is active WHEN there is an active line" do
      expect(plan.coverage_on(as_of).status).to eq :active
    end

    it "is inactive WHEN the only line is inactive" do
      expect(status_of(status: :inactive)).to eq :inactive
    end

    it "says nothing WHEN no line says active or inactive, never inactive" do
      expect(status_of(status: nil, benefit_type: :co_payment)).to be_nil
    end

    it "is non_covered WHEN the payer says only that the plan is not covered: not a denial of coverage" do
      expect(status_of(status: :non_covered)).to eq :non_covered
    end

    it "is inactive WHEN the plan ended before the day asked about, though a line says active" do
      expect(status_of(ends_on: "20260531")).to eq :inactive
    end

    it "is inactive WHEN the plan begins after the day asked about" do
      expect(status_of(begins_on: "20260602")).to eq :inactive
    end

    it "is active on the plan's last day" do
      expect(status_of(ends_on: "20260601")).to eq :active
    end

    it "ignores a plan date it cannot read" do
      expect(status_of(ends_on: "garbled")).to eq :active
    end

    it "says nothing WHEN only another service type is active: nothing was said about the plan" do
      expect(status_of(service_types: ["33"])).to be_nil
    end

    it "is active WHEN the plan carries a term on 30 and no status line, since the term implies coverage" do
      expect(status_of(status: nil, benefit_type: :co_payment, service_types: ["30"])).to eq :active
    end

    it "is active WHEN the plan ended and its line on 30 has dates of its own that include the day" do
      expect(status_of(ends_on: "20260531", line_ends_on: "20261231")).to eq :active
    end

    it "keeps Coverage's finding for the detail" do
      expect(plan.coverage_on(as_of).code).to be_nil
    end
  end

  describe "Medicaid" do
    it "has no Medicaid ID WHEN the answer names none" do
      expect(plan.medicaid_id).to be_nil
    end

    context "WHEN the plan carries the state Medicaid ID of an MCO plan" do
      let(:found) { [found_plan([line.merge(state_insurance_id: "MEDID0001")], held)] }

      it "holds the MCO plan's ID" do
        expect(plan.member_id).to eq "MOCKID0002"
      end

      it "holds the state Medicaid ID" do
        expect(plan.medicaid_id).to eq "MEDID0001"
      end
    end

    context "WHEN an MCO's plan names a Medicaid payer that came back as its own plan" do
      let(:mco_line) { line.merge(primary_payer_code: "MCAID9") }
      let(:found) do
        [found_plan([mco_line], held),
         found_plan([{ member_id: "MEDID0002", payer_code: "MCAID9", status: :active }], held)]
      end

      it "is one plan" do
        expect(plans.size).to eq 1
      end

      it "holds the Medicaid plan's ID" do
        expect(plan.medicaid_id).to eq "MEDID0002"
      end

      it "holds both plans' lines" do
        expect(plan.benefits.map(&:member_id)).to eq %w[MOCKID0002 MEDID0002]
      end

      it "prefers the state ID on the MCO's own plan" do
        found[0] = found_plan([mco_line.merge(state_insurance_id: "MEDID0001")], held)

        expect(plan.medicaid_id).to eq "MEDID0001"
      end
    end

    context "WHEN a Medicaid plan is tied to no MCO" do
      let(:found) { [found_plan([line.merge(payer_code: "MCAID9", payer_name: "STATE MEDICAID")], held)] }

      it "is a plan of its own" do
        expect(plans.size).to eq 1
      end
    end

    context "WHEN neither plan names a payer" do
      let(:found) { [found_plan([line.merge(payer_code: nil)], held), found_plan([line.merge(payer_code: nil)], held)] }

      it "pairs neither with the other" do
        expect(plans.size).to eq 2
      end
    end
  end

  describe "who the payer matched" do
    it "is the person as the payer holds them" do
      expect([plan.person.first_name, plan.person.last_name, plan.person.date_of_birth])
        .to eq(%w[TESTFIRST TESTLAST 19800101])
    end

    context "WHEN the payer named nobody" do
      let(:found) { [found_plan([line], nil)] }

      it "has no person or relationship" do
        expect([plan.person, plan.relationship]).to eq([nil, nil])
      end
    end

    context "WHEN the payer holds another address" do
      let(:found) { [found_plan([line], held.merge(address_line1: "9 Other Road", postal_code: "11111"))] }

      it "carries the payer's address" do
        expect(plan.person.address.to_h).to eq(line1: "9 Other Road", postal_code: "11111")
      end
    end

    it "reads each plan's person apart" do
      found << found_plan([line.merge(payer_code: "P2", member_id: "OTHER01")], held.merge(first_name: "OTHER"))

      expect(plans.map { |each| [each.member_id, each.person.first_name] })
        .to eq [%w[MOCKID0002 TESTFIRST], %w[OTHER01 OTHER]]
    end
  end

  describe "#relationship" do
    def relationship(role = :subscriber, **fields)
      found.replace([EdiGem::FoundPlan.new(benefits: [EdiGem::Benefit.new(line)],
                                           people: [EdiGem::Person.new(role: role, **held, **fields)])])
      plan.relationship
    end

    it "is self WHEN the payer matched the policyholder (18)" do
      expect(relationship(relationship_code: "18")).to eq :self
    end

    it "is dependent WHEN the payer matched a dependent" do
      expect(relationship(:dependent)).to eq :dependent
    end

    it "is nil WHEN the payer did not say" do
      expect(relationship).to be_nil
    end
  end

  describe "the plan's name and number" do
    it "is the first of its own lines that names one, active or not" do
      found.replace([found_plan([line.merge(status: :inactive, plan_name: "FIRST PLAN", plan_number: nil),
                                 line.merge(plan_name: "ACTIVE PLAN")], held)])

      expect([plan.plan_name, plan.plan_number]).to eq(["FIRST PLAN", "PLAN01"])
    end

    it "is never the Medicaid plan's" do
      found.replace([found_plan([line.merge(primary_payer_code: "MCAID9", plan_name: nil, plan_number: nil)], held),
                     found_plan([{ payer_code: "MCAID9", status: :active, plan_name: "STATE PLAN" }], held)])

      expect([plan.plan_name, plan.plan_number, plan.lines.map(&:plan_name)]).to eq([nil, nil, [nil, "STATE PLAN"]])
    end

    it "reads the group number on a discovery's subscriber" do
      source, = stedi_answering(canned("stedi_discovery_complete"))
      inquiry = EdiGem::Inquiry::Discovery.new(subscriber: EdiGem::Subscriber.new(**held), as_of: "20260901",
                                               provider: EdiGem::Provider.new(npi: "1999999984",
                                                                              organization_name: "EXAMPLECLINIC"))
      discovered = source.discovery(inquiry).medical_plans.fetch(0)

      expect([discovered.plan_name, discovered.plan_number, discovered.group_number])
        .to eq(["EXAMPLE MEDICAID PLAN", "PLAN0002", "GRP0002"])
    end
  end

  describe "the plan's own dates" do
    def dates(**fields)
      found.replace([found_plan([line.merge(fields)], held)])
      [plan.plan_begins_on, plan.plan_ends_on]
    end

    it "are Dates" do
      expect(dates(plan_begins_on: "20260101", plan_ends_on: "20261231")).to eq([Date.new(2026, 1, 1),
                                                                                 Date.new(2026, 12, 31)])
    end

    it "are nil WHEN absent" do
      expect(dates).to eq([nil, nil])
    end

    it "are nil WHEN not a real day, or not a string" do
      expect(dates(plan_begins_on: "20261340", plan_ends_on: 20_261_231)).to eq([nil, nil])
    end

    PlanDateForms::ALL.each do |form, (dates, expected)|
      it "are read from a discovery's planDateInformation WHEN it holds #{form}" do
        body = JSON.parse(File.read(File.join(CannedSource::FIXTURES, "stedi_discovery_complete.json")))
        body["items"][0]["planDateInformation"] = dates
        source, = stedi_answering(canned_body(body))
        inquiry = EdiGem::Inquiry::Discovery.new(subscriber: EdiGem::Subscriber.new(**held), as_of: "20260901",
                                                 provider: EdiGem::Provider.new(npi: "1999999984",
                                                                                organization_name: "EXAMPLECLINIC"))
        discovered = source.discovery(inquiry).medical_plans.fetch(0)

        expect([discovered.plan_begins_on, discovered.plan_ends_on]).to eq(expected)
      end
    end
  end

  # The code a caller records comes from the one Finding that decides the status.
  describe "the status code behind the status" do
    def finding(**fields)
      found.replace([found_plan([line.merge(fields)], held)])
      [plan.coverage_on(as_of).status, plan.coverage_on(as_of).code]
    end

    it "is the active line's, code 5 included" do
      expect(finding(status_code: "5")).to eq([:active, "5"])
    end

    it "is nil WHEN an implied term decided" do
      expect(finding(status: nil, benefit_type: :co_payment, service_types: ["30"])).to eq([:active, nil])
    end
  end

  it "prints what it holds, never a person" do
    expect(plan.inspect)
      .to eq("#<EdiGem::MedicalPlan #<EdiGem::FoundPlan benefits=1 people=subscriber> medicaid=false>")
  end
end
