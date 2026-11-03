# frozen_string_literal: true

require "date"

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

  it "gives its fields as the keys of a question read them" do
    expect(person.to_h).to eq(first_name: "José", last_name: "Núñez", date_of_birth: Date.new(1980, 1, 2))
  end

  it "is equal to another holding the same fields, and only to one of its kind" do
    same = described_class.new(**person.to_h)

    expect([person == same, person.eql?(same), person.hash == same.hash, person == person.to_h])
      .to eq([true, true, true, false])
  end

  it "is sent as the subscriber on an ID, birth date as YYYYMMDD" do
    expect(person.subscriber(member_id: "MOCKID0001"))
      .to have_attributes(member_id: "MOCKID0001", first_name: "José", date_of_birth: "19800102", relationship: :self)
  end

  it "is sent as a dependent of unknown relationship, with no birth date when it has none" do
    expect(person.with(date_of_birth: nil).subscriber(member_id: "MOCKID0001", relationship: nil))
      .to have_attributes(date_of_birth: nil, relationship: nil)
  end

  it "has another spelling WHEN a name holds an accented letter written another way too" do
    expect([person, person.with(last_name: "Müller"), person.with(first_name: "Đuro"), person.with(first_name: "Peña")]
             .map(&:another_spelling?)).to eq([false, true, true, false])
  end

  it "spells both names the other way" do
    expect(person.with(first_name: "Đuro", last_name: "Müller").another_spelling.to_h)
      .to include(first_name: "JURO", last_name: "MUELLER")
  end

  it "is punctuated WHEN a name holds an apostrophe or hyphen" do
    expect([person, person.with(last_name: "O'Brien"), person.with(first_name: "Mary-Ann")].map(&:punctuated?))
      .to eq([false, true, true])
  end

  it "is asked without punctuation as a payer holding the names that way would" do
    unpunctuated = person.with(first_name: "D'Andre", last_name: "O'Brien-Smith").unpunctuated

    expect(unpunctuated.to_h)
      .to eq(first_name: "DANDRE", last_name: "OBRIEN SMITH", date_of_birth: Date.new(1980, 1, 2))
  end

  it "names nobody WHEN inspected or printed" do
    expect([person.inspect, person.to_s]).to all(eq "#<EdiGem::Person::Asked>")
  end

  it "cannot be changed in place" do
    expect(person).to be_frozen
  end
end
