# frozen_string_literal: true

RSpec.describe EdiGem::FoundPlan do
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

  it "reads the plan's coverage by the two-part test" do
    expect(plan([holder]).coverage_on("20260901")).to be_active
  end

  describe "#medical?" do
    def medical?(*service_types)
      lines = service_types.map { |types| EdiGem::Benefit.new(status: :active, service_types: types) }
      described_class.new(benefits: lines, people: []).medical?
    end

    it "is false WHEN every line is dental or vision" do
      expect([medical?(%w[35], %w[AL]), medical?(%w[23 28 41 AO])]).to eq([false, false])
    end

    it "is true WHEN a line covers medical care beside dental" do
      expect(medical?(%w[35 30])).to be(true)
    end

    it "is true WHEN no line names a service type" do
      expect([medical?(nil), medical?([])]).to eq([true, true])
    end
  end

  describe "#names_as_primary_payer?" do
    def found(**fields) = described_class.new(benefits: [EdiGem::Benefit.new(fields)], people: [])

    it "is true WHEN the plan names the other plan's payer as its primary payer" do
      expect(found(primary_payer_code: "MCAID9").names_as_primary_payer?(found(payer_code: "MCAID9"))).to be(true)
    end

    # Stedi's Medicaid guide pairs by the related entity's name, since its coding varies by state.
    it "is true WHEN the plan names the other plan's payer by name, case and spacing aside" do
      medicaid = found(payer_code: "77027", payer_name: "MEDICAID  FLORIDA")

      expect(found(primary_payer_code: "OTHER", primary_payer_name: "Medicaid Florida")
               .names_as_primary_payer?(medicaid)).to be(true)
    end

    it "is false WHEN it names another payer by name, or a blank name" do
      medicaid = found(payer_code: "77027", payer_name: "MEDICAID FLORIDA")

      expect([found(primary_payer_name: "MEDICAID GEORGIA"), found(primary_payer_name: " ")]
               .map { |plan| plan.names_as_primary_payer?(medicaid) }).to eq([false, false])
    end

    it "is false WHEN it names another payer, or none" do
      medicaid = found(payer_code: "MCAID9")

      expect([found(primary_payer_code: "OTHER"), found(primary_payer_code: " "), found]
               .map { |plan| plan.names_as_primary_payer?(medicaid) }).to eq([false, false, false])
    end
  end

  it "prints its size and roles, never a person" do
    expect(plan([holder, patient]).inspect).to eq("#<EdiGem::FoundPlan benefits=2 people=subscriber,dependent>")
  end
end
