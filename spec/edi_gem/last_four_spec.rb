# frozen_string_literal: true

require "pp"

# Every number here is made up.
RSpec.describe EdiGem::LastFour do
  def last_four(ssn) = described_class.of(ssn)

  it "is nil WHEN nothing was given" do
    expect([last_four(nil), last_four(""), last_four("  ")]).to all(be_nil)
  end

  it "reads the last four of a whole number, a masked one, or four digits alone" do
    expect(%w[000001234 XXX-XX-1234 1234].map { |ssn| last_four(ssn) == last_four("1234") })
      .to all(be true)
  end

  it "is unreadable WHEN the end is masked or there are fewer than four digits" do
    expect(["000-00-XXXX", "000-00-****", "12", "***"].map { |ssn| last_four(ssn).readable? }).to all(be false)
  end

  it "equals one with the same last four, and no other kind" do
    expect([last_four("1234") == last_four("000-00-1234"), last_four("1234") == last_four("4321"),
            last_four("1234") == "1234"]).to eq([true, false, false])
  end

  [false, true].each do |revealed|
    context "WHEN EdiGem.reveal is #{revealed}" do
      around do |example|
        EdiGem.reveal = revealed
        example.run
      ensure
        EdiGem.reveal = false
      end

      it "prints no digit, by inspect, to_s or pp" do
        kept = last_four("000-00-1234")

        expect([kept.inspect, kept.to_s, PP.pp(kept, +"")].join).to_not include("1234")
      end
    end
  end
end
