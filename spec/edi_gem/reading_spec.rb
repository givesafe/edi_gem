# frozen_string_literal: true

RSpec.describe EdiGem::Reading do
  describe "one schema over two dialects" do
    it "reads a benefit out of a raw 271" do
      reading = described_class.new(document: EdiGem::Document::X12.new(covered_271),
                                    schema: EdiGem::Schema.fetch(:x12_271))

      expect(reading.benefits.first.status).to eq(:active)
    end

    it "reads the same benefit out of the JSON a vendor returns" do
      body = { "benefitsInformation" => [{ "code" => "1", "planCoverage" => "Example Medicaid" }] }
      reading = described_class.new(document: EdiGem::Document::Json.new(body),
                                    schema: EdiGem::Schema.fetch(:stedi))

      expect(reading.benefits.first.status).to eq(:active)
    end
  end

  # A 271 scatters one plan across several blocks, and a caller cannot put them back together
  # because it cannot see which item a benefit line came from. So the reading does it.
  describe "assembling a plan out of the blocks that describe it" do
    def read(body, schema: :stedi)
      described_class.new(document: EdiGem::Document::Json.new(body),
                          schema: EdiGem::Schema.fetch(schema)).benefits
    end

    let(:one_payer) do
      { "payer" => { "name" => "Example Medicaid", "payorIdentification" => "38333" },
        "subscriber" => { "memberId" => "MEM1" },
        "benefitsInformation" => [{ "code" => "1" }, { "code" => "B" }] }
    end

    it "puts the payer that answered on every benefit line it sent" do
      expect(read(one_payer).map(&:payer_code)).to eq(%w[38333 38333])
    end

    it "keeps the benefit lines apart, because they are what the plan covers" do
      expect(read(one_payer).map(&:status)).to eq([:active, nil])
    end

    it "reads a line that describes a term of the plan as a benefit rather than a status" do
      expect(read(one_payer).map(&:benefit_type)).to eq([nil, :co_payment])
    end

    it "reads the line of business off an eligibility answer, not only off a discovery" do
      body = one_payer.merge("benefitsInformation" => [{ "code" => "1", "insuranceType" => "MC" }])

      expect(read(body).map(&:insurance_type)).to eq(["MC"])
    end

    it "reads the state's own id and the programme off an eligibility answer, not only off a discovery" do
      body = one_payer.merge("planInformation" => { "medicaidRecipientIdNumber" => "STATE1",
                                                    "groupDescription" => "Example State Medicaid" })

      expect(read(body).map { |line| [line.state_insurance_id, line.group_description] }.uniq)
        .to eq([["STATE1", "Example State Medicaid"]])
    end

    it "reads the subscriber the answer was about onto each of them" do
      expect(read(one_payer).map(&:member_id)).to eq(%w[MEM1 MEM1])
    end

    # The block holding the payer code carries no status and the block holding the status carries
    # no payer code, so handing either out on its own is half an answer.
    it "returns one plan rather than one object per block read" do
      expect(read(one_payer).length).to eq(2)
    end

    it "is a plan on its own WHEN nothing deeper describes it" do
      body = { "payer" => { "payorIdentification" => "38333" } }

      expect(read(body).map(&:payer_code)).to eq(["38333"])
    end

    it "reads nothing out of an answer that named nothing" do
      expect(read({})).to be_empty
    end

    # The failure this exists to prevent: a discovery finds two plans, and the benefit lines of
    # one are read as belonging to the other. Nothing in a flat list of blocks could tell them
    # apart, which is why the caller cannot be asked to do this.
    describe "two plans in one answer" do
      let(:two_plans) do
        { "items" => [
          { "payer" => { "payorIdentification" => "14163" },
            "benefitsInformation" => [{ "code" => "6" }] },
          { "payer" => { "payorIdentification" => "25463" },
            "benefitsInformation" => [{ "code" => "1" }, { "code" => "C" }] }
        ] }
      end

      it "gives each plan's benefit lines that plan's own payer" do
        expect(read(two_plans, schema: :stedi_discovery).map(&:payer_code))
          .to eq(%w[14163 25463 25463])
      end

      it "keeps each plan's own answer about whether it is in force" do
        expect(read(two_plans, schema: :stedi_discovery).map(&:status))
          .to eq([:inactive, :active, nil])
      end

      it "carries the deductible line as a benefit of the plan it belongs to" do
        expect(read(two_plans, schema: :stedi_discovery).map(&:benefit_type))
          .to eq([nil, nil, :deductible])
      end
    end

    # A real 271 sends a line per thing the plan covers, not one. Read as one place, every line
    # after the first overwrites the one before it.
    describe "a 271 with several lines, for two subscribers" do
      subject(:benefits) do
        described_class.new(document: EdiGem::Document::X12.new(body),
                            schema: EdiGem::Schema.fetch(:x12_271)).benefits
      end

      let(:body) do
        x12_271("ST*271*0001*005010X279A1~",
                "HL*1**20*1~", "NM1*PR*2*EXAMPLE MEDICAID*****PI*99999~",
                "HL*2*1*21*1~", "NM1*1P*2*EXAMPLECLINIC*****XX*1999999984~",
                "HL*3*2*22*0~", "NM1*IL*1*LOVELACE*ADA****MI*MEM1~",
                "EB*1**30**EXAMPLE MEDICAID~", "AMT*R*20~", "EB*C**30~",
                "HL*4*2*22*0~", "NM1*IL*1*HOPPER*GRACE****MI*MEM2~",
                "EB*6**30~",
                "SE*14*0001~")
      end

      it "keeps each line apart" do
        expect(benefits.map { |benefit| [benefit.status, benefit.benefit_type] })
          .to eq([[:active, nil], [nil, :deductible], [:inactive, nil]])
      end

      it "puts each subscriber's own id on that subscriber's lines" do
        expect(benefits.map(&:member_id)).to eq(%w[MEM1 MEM1 MEM2])
      end

      it "puts the payer above both on every line" do
        expect(benefits.map(&:payer_code)).to eq(%w[99999 99999 99999])
      end

      it "keeps an amount with the line it followed" do
        expect(benefits.map(&:share_of_cost)).to eq(["20", nil, nil])
      end
    end
  end

  describe "rejection levels" do
    it "keeps the lane a 271 put the rejection in" do
      reading = described_class.new(document: EdiGem::Document::X12.new(rejected_271),
                                    schema: EdiGem::Schema.fetch(:x12_271))

      expect(reading.rejections.map(&:level)).to eq([:subscriber])
    end

    it "reads a vendor's nested lanes rather than its flattened list" do
      body = { "provider" => { "aaaErrors" => [{ "code" => "43" }] },
               "subscriber" => { "aaaErrors" => [{ "code" => "72" }] } }
      reading = described_class.new(document: EdiGem::Document::Json.new(body),
                                    schema: EdiGem::Schema.fetch(:stedi))

      expect(reading.rejections.map(&:level)).to contain_exactly(:provider, :subscriber)
    end
  end

  # Stedi's planInformation.priorIdNumber, "The prior identifier number": X12's REF*Q4, the ID the
  # member ID replaced.
  describe "the ID the payer's member ID replaced" do
    def prior(plan_information, schema:)
      body = { "subscriber" => { "memberId" => "MEM2" }, "planInformation" => plan_information,
               "benefitsInformation" => [{ "code" => "1" }] }
      body = { "items" => [body] } if schema == :stedi_discovery
      described_class.new(document: EdiGem::Document::Json.new(body),
                          schema: EdiGem::Schema.fetch(schema)).benefits.map { |line| line[:prior_member_id] }
    end

    %i[stedi stedi_discovery].each do |schema|
      context "WHEN read with #{schema}" do
        it "reads the prior identifier number onto each line, beside the member ID" do
          expect(prior({ "priorIdNumber" => "MEM1" }, schema: schema)).to eq(["MEM1"])
        end

        it "reads none WHEN the payer names no prior ID" do
          expect(prior({ "groupNumber" => "GRP01" }, schema: schema)).to eq([nil])
        end
      end
    end
  end

  # One key holds a single date on one coverage and a range on the next, and the begin and end a
  # payer sends of their own win over either.
  describe "a plan's dates" do
    def dates(plan_dates, schema:)
      body = { "planDateInformation" => plan_dates, "benefitsInformation" => [{ "code" => "1" }] }
      body = { "items" => [body] } if schema == :stedi_discovery
      benefit = described_class.new(document: EdiGem::Document::Json.new(body),
                                    schema: EdiGem::Schema.fetch(schema)).benefits.first
      [benefit.begins_on, benefit.ends_on]
    end

    %i[stedi stedi_discovery].each do |schema|
      context "WHEN read with #{schema}" do
        it "reads both ends of a plan sent as a range" do
          expect(dates({ "plan" => "20260820-20260930" }, schema: schema)).to eq(%w[20260820 20260930])
        end

        it "reads a plan sent as one date as where it starts" do
          expect(dates({ "plan" => "20260826" }, schema: schema)).to eq(["20260826", nil])
        end

        it "reads the plan's own begin over where its period starts" do
          sent = { "plan" => "20260101-20261231", "planBegin" => "20260301" }

          expect(dates(sent, schema: schema).first).to eq("20260301")
        end

        it "reads the member's eligibility begin over the plan's" do
          sent = { "planBegin" => "20260301", "eligibilityBegin" => "20260601" }

          expect(dates(sent, schema: schema).first).to eq("20260601")
        end

        it "reads the plan's own end over where its period ends" do
          sent = { "plan" => "20260101-20261231", "planEnd" => "20260930" }

          expect(dates(sent, schema: schema).last).to eq("20260930")
        end
      end
    end

    it "keeps the plan's own period readable apart from the span" do
      body = { "planDateInformation" => { "plan" => "20260820-20260930", "eligibilityBegin" => "20260901" } }
      benefit = described_class.new(document: EdiGem::Document::Json.new(body),
                                    schema: EdiGem::Schema.fetch(:stedi)).benefits.first

      expect([benefit[:plan_begins_on], benefit[:plan_ends_on]]).to eq(%w[20260820 20260930])
    end
  end

  describe "a field declared twice" do
    let(:schema) do
      EdiGem::Schema.new(:declared_twice).tap do |schema|
        schema.benefit("planDateInformation") do
          field :begins_on, from: "eligibilityBegin"
          field :begins_on, from: "planBegin"
        end
      end
    end

    def begins_on(dates)
      body = { "planDateInformation" => dates }
      described_class.new(document: EdiGem::Document::Json.new(body), schema: schema).benefits.first.begins_on
    end

    it "reads the first declaration WHEN it holds a value" do
      expect(begins_on("eligibilityBegin" => "20260601", "planBegin" => "20260101")).to eq("20260601")
    end

    it "reads the next declaration WHEN the first is absent" do
      expect(begins_on("planBegin" => "20260101")).to eq("20260101")
    end

    it "reads past a first declaration that is present and empty" do
      expect(begins_on("eligibilityBegin" => "", "planBegin" => "20260101")).to eq("20260101")
    end
  end

  describe "codecs" do
    it "decodes an AAA03 into the reason it stands for" do
      reading = described_class.new(document: EdiGem::Document::X12.new(rejected_271),
                                    schema: EdiGem::Schema.fetch(:x12_271))

      expect(reading.rejections.first.code).to eq(:member_id_invalid)
    end
  end
end
