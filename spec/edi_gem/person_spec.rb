# frozen_string_literal: true

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

  it "gives the fields an identity comparison reads" do
    expect(person.identity).to eq(first_name: "TESTFIRST", last_name: "TESTLAST",
                                  date_of_birth: "20100101")
  end

  it "prints which fields it holds, never their values" do
    expect(person.inspect).to eq(
      "#<EdiGem::Person dependent first_name,last_name,date_of_birth,relationship_code," \
      "maintenance_type_code,maintenance_reason_code>"
    )
  end
end
