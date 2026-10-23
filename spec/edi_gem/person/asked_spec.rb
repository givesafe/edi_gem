# frozen_string_literal: true

require "date"
require "pp"

RSpec.describe EdiGem::Person::Asked do
  let(:person) { described_class.new(first_name: "José", last_name: "Núñez", date_of_birth: Date.new(1980, 1, 2)) }

  it "is complete with both names and a birth date" do
    expect(person).to be_complete
  end

  it "isn't complete without a birth date" do
    expect(person.with(date_of_birth: nil)).to_not be_complete
  end

  it "isn't complete with a blank name" do
    expect(person.with(last_name: "  ")).to_not be_complete
  end

  it "spells the names as they are sent to a payer, keeping the birth date" do
    expect(person.plain).to eq person.with(first_name: "JOSE", last_name: "NUNEZ")
  end

  it "gives its fields as the keys of a question read them" do
    expect(person.plain.to_h).to eq(first_name: "JOSE", last_name: "NUNEZ", date_of_birth: Date.new(1980, 1, 2))
  end

  it "is equal to another holding the same fields, and only to one of its kind" do
    same = described_class.new(**person.to_h)

    expect([person == same, person.eql?(same), person.hash == same.hash, person == person.to_h])
      .to eq([true, true, true, false])
  end

  describe "#same_as?" do
    it "is true for two spellings of one name" do
      expect(person.same_as?(person.with(first_name: "jose", last_name: "Nunez"))).to be true
    end

    it "is false for another name a letter apart" do
      expect(person.with(first_name: "Leon").same_as?(person.with(first_name: "Leo"))).to be false
    end

    it "is false for a name cut short, which only a payer does" do
      expect(person.with(first_name: "Maximiliano").same_as?(person.with(first_name: "Maximili"))).to be false
    end

    it "is false for another birth date" do
      expect(person.same_as?(person.with(date_of_birth: Date.new(1980, 1, 3)))).to be false
    end
  end

  it "is sent as the subscriber on an ID, birth date as YYYYMMDD" do
    expect(person.subscriber(member_id: "MOCKID0001"))
      .to have_attributes(member_id: "MOCKID0001", first_name: "José", date_of_birth: "19800102", relationship: :self)
  end

  it "is sent as a dependent of unknown relationship, with no birth date when it has none" do
    expect(person.with(date_of_birth: nil).subscriber(member_id: "MOCKID0001", relationship: nil))
      .to have_attributes(date_of_birth: nil, relationship: nil)
  end

  it "names nobody WHEN inspected or printed" do
    expect([person.inspect, person.to_s]).to all(eq "#<EdiGem::Person::Asked>")
  end

  it "cannot be changed in place" do
    expect(person).to be_frozen
  end

  describe "the details given beside the core" do
    let(:address) { EdiGem::Address.new(line1: "1 Example St", postal_code: "40000") }
    let(:given) { person.with(address: address, ssn: "000-00-1234") }

    def held(**fields)
      EdiGem::Person.new(role: :subscriber, address_line1: "1 EXAMPLE ST", postal_code: "40000", ssn: "XXX-XX-1234",
                         **fields)
    end

    it "keeps the core apart: to_h, complete? and same_as? read only the names and birth date" do
      expect([given.to_h, given.complete?, given.same_as?(person)]).to eq([person.to_h, true, true])
    end

    it "equals one asked before either could be given WHEN it carries neither" do
      today = described_class.new(first_name: "José", last_name: "Núñez", date_of_birth: Date.new(1980, 1, 2))

      expect([person == today, person.hash == today.hash, person.address]).to eq([true, true, nil])
    end

    it "isn't equal to the same core given other details" do
      expect([given == person, given == given.with(ssn: "4321"), given == given.with(first_name: "José")])
        .to eq([false, false, true])
    end

    it "keeps them through #with and #plain" do
      expect([given.plain.given_fields(held), given.plain.address])
        .to eq([{ address: :matched, ssn_last_four: :matched }, address])
    end

    it "compares each with the person the payer holds" do
      expect(given.given_fields(held(postal_code: "40001", ssn: "XXX-XX-4321")))
        .to eq(address: :differs, ssn_last_four: :differs)
    end

    it "is not_returned for each WHEN the payer holds neither, or named nobody" do
      expect([given.given_fields(EdiGem::Person.new(role: :subscriber)), given.given_fields(nil)])
        .to all(eq(address: :not_returned, ssn_last_four: :not_returned))
    end

    it "is not_compared for each WHEN ours can't be compared, which is not the payer's lack" do
      unreadable = person.with(address: EdiGem::Address.new(city: "Example"), ssn: "000-00-XXXX")

      expect([unreadable.given_fields(held), unreadable.given_fields(nil)])
        .to all(eq(address: :not_compared, ssn_last_four: :not_compared))
    end

    it "names only the details it carries" do
      expect([person.given_fields(held), person.with(address: address).given_fields(held)])
        .to eq([{}, { address: :matched }])
    end

    [false, true].each do |revealed|
      it "prints no digit of the SSN WHEN EdiGem.reveal is #{revealed}" do
        EdiGem.reveal = revealed

        expect([given.inspect, given.to_s, PP.pp(given, +"")].join).to_not include("1234")
      ensure
        EdiGem.reveal = false
      end
    end
  end
end
