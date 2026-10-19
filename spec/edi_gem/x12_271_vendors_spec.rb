# frozen_string_literal: true

# The X12 271 read against worked examples beyond Stedi's: Office Ally's published 271 and a
# synthetic share-of-cost answer.
RSpec.describe "reading a 271 from another vendor" do
  def reading(body)
    EdiGem::Reading.new(document: EdiGem::Payload.new(body: body, dialect: :x12).document,
                        schema: EdiGem::Schema.fetch(:x12_271))
  end

  def attribute(body, field)
    reading(body).benefits.filter_map { |benefit| benefit[field] }
  end

  describe "Office Ally's published 271" do
    it "reads the active benefit" do
      expect(attribute(office_ally_271, :status)).to eq([:active])
    end

    it "reads the member id off the subscriber, not off whatever NM1 comes first" do
      expect(attribute(office_ally_271, :member_id)).to eq(["UUE12345678U5"])
    end

    it "names the payer that answered" do
      expect(attribute(office_ally_271, :payer_name)).to eq(["BLUE SHIELD SOMEWHERE"])
    end

    # Three DTPs sit in the subscriber loop -- 291, 356 and 357 -- and reading the segment without
    # its qualifier cannot say which is which.
    it "tells the eligibility dates apart from the plan date" do
      expect([attribute(office_ally_271, :begins_on), attribute(office_ally_271, :ends_on)])
        .to eq([["20070701"], ["99991231"]])
    end

    it "reads the insurance type the plan was written under" do
      expect(attribute(office_ally_271, :insurance_type)).to eq(["HM"])
    end

    # The commonization is the point: a caller must not have to know which vendor answered in
    # order to read a field. X12 repeats an element, the JSON vendors send a list.
    it "reports service types as a list, exactly as the JSON sources do" do
      expect(attribute(office_ally_271, :service_types)).to eq([["30"]])
    end
  end

  describe "a share of cost" do
    # Eligible, and owing a spend-down before the coverage pays.
    it "reads the coverage as active" do
      expect(attribute(share_of_cost_271, :status)).to eq([:active])
    end

    it "reads the amount the member owes first" do
      expect(attribute(share_of_cost_271, :share_of_cost)).to eq(["20"])
    end
  end

  describe "an element the payer left empty" do
    it "is absent rather than an empty string, because blank is not a fact" do
      expect(reading(covered_271).benefits.map(&:attributes).map(&:keys).flatten)
        .to_not include(:insurance_type)
    end
  end
end
