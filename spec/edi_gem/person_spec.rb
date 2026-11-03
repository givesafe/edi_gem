# frozen_string_literal: true

require "json"
require "pp"

RSpec.describe EdiGem::Person do
  subject(:person) do
    described_class.new(role: :dependent, first_name: "TESTFIRST", last_name: "TESTLAST",
                        date_of_birth: "20100101", relationship_code: "19",
                        maintenance_type_code: "001", maintenance_reason_code: "25")
  end

  it "knows it came back as a dependent" do
    expect(person).to be_dependent
  end

  it "reads 001 with 25 as the payer correcting the identity it was sent" do
    expect(person).to be_identity_corrected
  end

  it "reads a change for another reason as no identity correction" do
    other = described_class.new(role: :subscriber, maintenance_type_code: "001",
                                maintenance_reason_code: "XX")

    expect(other).not_to be_identity_corrected
  end

  describe "#relationship" do
    def relationship(role = :subscriber, **fields) = described_class.new(role: role, **fields).relationship

    it "is self WHEN the payer matched the policyholder (18)" do
      expect(relationship(relationship_code: "18")).to eq(:self)
    end

    it "is dependent WHEN the payer names another relationship" do
      expect(relationship(relationship_code: "19")).to eq(:dependent)
    end

    it "is dependent WHEN the payer matched a dependent" do
      expect(relationship(:dependent, relationship_code: "18")).to eq(:dependent)
    end

    it "is nil WHEN the payer did not say" do
      expect(relationship).to be_nil
    end
  end

  it "holds the address the payer has on record" do
    found = described_class.new(role: :subscriber, address_line1: "1 Example St", city: "Example",
                                postal_code: "40000")

    expect(found.address.to_h).to eq(line1: "1 Example St", city: "Example", postal_code: "40000")
  end

  it "holds no address when the payer sent none" do
    expect(person.address).to be_nil
  end

  it "holds the names and birth date as the payer sent them" do
    expect([person.first_name, person.last_name, person.date_of_birth]).to eq(%w[TESTFIRST TESTLAST 20100101])
  end

  it "holds a suffix the payer sent apart as part of the last name" do
    expect(described_class.new(role: :subscriber, last_name: "TESTLAST", suffix: "JR").last_name).to eq("TESTLAST JR")
  end

  it "reads the suffix of a 271's NM107 into the last name" do
    body = x12_271("GS*HB*SENDER*RECEIVER*20260903*1200*1*X*005010X279A1~",
                   "ST*271*0001~", "HL*1**20*1~", "NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*38333~",
                   "HL*2*1*21*1~", "NM1*1P*2*EXAMPLECLINIC*****XX*1999999984~",
                   "HL*3*2*22*0~", "NM1*IL*1*LOVELACE*ADA***JR*MI*MEM123~", "EB*1**30~",
                   "SE*8*0001~", "GE*1*1~", "IEA*1*000000001~")
    reading = EdiGem::Reading.new(document: EdiGem::Payload.new(body: body, dialect: :x12).document,
                                  schema: EdiGem::Schema.fetch(:x12_271))

    expect(reading.people.first.last_name).to eq("LOVELACE JR")
  end

  it "prints which fields it holds, never their values" do
    expect(person.inspect).to eq(
      "#<EdiGem::Person dependent first_name,last_name,date_of_birth,relationship_code," \
      "maintenance_type_code,maintenance_reason_code>"
    )
  end

  it "prints that it holds an address, never the address" do
    found = described_class.new(role: :subscriber, city: "Example")

    expect(found.inspect).to eq("#<EdiGem::Person subscriber address>")
  end
end
