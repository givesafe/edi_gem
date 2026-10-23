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

  describe "#born_on" do
    def born_on(date_of_birth) = described_class.new(role: :subscriber, date_of_birth: date_of_birth).born_on

    it "reads the payer's YYYYMMDD as a Date" do
      expect(born_on("19800102")).to eq(Date.new(1980, 1, 2))
    end

    it "reads a dashed date too" do
      expect(born_on("1980-01-02")).to eq(Date.new(1980, 1, 2))
    end

    it "is nil WHEN the payer sent no date, or none it can read" do
      expect([born_on(nil), born_on("garbled")]).to eq([nil, nil])
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

  it "prints that it holds an address, never the address" do
    found = described_class.new(role: :subscriber, city: "Example")

    expect(found.inspect).to eq("#<EdiGem::Person subscriber address>")
  end

  describe "the SSN the payer holds" do
    let(:found) { described_class.new(role: :subscriber, first_name: "TESTFIRST", ssn: "XXX-XX-1234") }

    it "keeps only the last four, which compare and never read back" do
      expect([found.ssn_last_four.compare(EdiGem::LastFour.of("1234")), found.ssn_last_four.to_s])
        .to eq([:matched, "#<EdiGem::LastFour>"])
    end

    it "is nil WHEN the payer sent none" do
      expect(person.ssn_last_four).to be_nil
    end

    it "names the field, never its value" do
      expect(found.inspect).to eq("#<EdiGem::Person subscriber first_name,ssn_last_four>")
    end

    [false, true].each do |revealed|
      it "prints no digit of it WHEN EdiGem.reveal is #{revealed}" do
        EdiGem.reveal = revealed

        expect([found.inspect, PP.pp(found, +"")].join).to_not include("1234")
      ensure
        EdiGem.reveal = false
      end
    end

    # Stedi's discovery answer, with the subscriber's SSN whole and a dependent's masked.
    def answer_with_ssns
      body = JSON.parse(File.read(File.join(CannedSource::FIXTURES, "stedi_discovery_complete.json")))
      body["items"][0]["subscriber"]["ssn"] = "000001234"
      body["items"][0]["dependent"] = { "firstName" => "TESTKID", "ssn" => "XXX-XX-4321" }
      canned_body(body)
    end

    it "is read from each person of a discovery's answer, whole or masked" do
      source, = stedi_answering(answer_with_ssns)
      asked = EdiGem::Subscriber.new(first_name: "A", last_name: "B", date_of_birth: "19800101")
      clinic = EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic")
      inquiry = EdiGem::Inquiry::Discovery.new(subscriber: asked, provider: clinic, as_of: "20260901")
      people = source.discovery(inquiry).found_plans.first.people

      expect(people.map { |each| each.ssn_last_four.compare(EdiGem::LastFour.of(each.dependent? ? "4321" : "1234")) })
        .to eq(%i[matched matched])
    end
  end
end
