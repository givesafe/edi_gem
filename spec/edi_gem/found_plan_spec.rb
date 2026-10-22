# frozen_string_literal: true

RSpec.describe EdiGem::FoundPlan do
  let(:asked) { { first_name: "Testfirst", last_name: "Testlast", date_of_birth: "20100101" } }
  let(:holder) do
    EdiGem::Person.new(role: :subscriber, first_name: "POLICY", last_name: "HOLDER", date_of_birth: "19700101",
                       relationship_code: "18")
  end
  let(:patient) do
    EdiGem::Person.new(role: :dependent, first_name: "TESTFIRST", last_name: "TESTLAST", date_of_birth: "20100101",
                       relationship_code: "19", city: "Example")
  end
  let(:benefits) do
    [EdiGem::Benefit.new(payer_code: "00001", member_id: "MOCK00001", status: :active, service_types: ["30"]),
     EdiGem::Benefit.new(payer_code: "00001", plan_name: "EXAMPLE PLAN", status: :active, service_types: ["1"])]
  end

  def plan(people) = described_class.new(benefits: benefits, people: people)

  it "reads a field of the plan from the first line that holds it" do
    expect([plan([holder]).payer_code, plan([holder]).member_id, plan([holder])[:plan_name]])
      .to eq(["00001", "MOCK00001", "EXAMPLE PLAN"])
  end

  it "is nil for a field no line holds" do
    expect(plan([holder])[:state_insurance_id]).to be_nil
  end

  it "names the dependent as the person matched when there is one" do
    expect(plan([holder, patient]).person).to eq(patient)
  end

  it "names the policyholder when there is no dependent" do
    expect(plan([holder]).person).to eq(holder)
  end

  it "compares the person matched with who was asked about" do
    expect(plan([holder, patient]).identify(asked).result).to be_matched
  end

  it "compares nobody as nothing returned" do
    expect(plan([]).identify(asked).then { |found| [found.person, found.result.matched?] }).to eq([nil, false])
  end

  it "reads the plan's coverage by the two-part test" do
    expect(plan([holder]).coverage_on("20260901")).to be_active
  end

  it "prints its size and roles, never a person" do
    expect(plan([holder, patient]).inspect).to eq("#<EdiGem::FoundPlan benefits=2 people=subscriber,dependent>")
  end
end
