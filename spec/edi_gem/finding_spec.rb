# frozen_string_literal: true

# What an answer established, one finding per row of the table on EdiGem::Finding. Every value here
# is made up.
RSpec.describe EdiGem::Finding do
  let(:day) { Date.new(2026, 6, 1) }
  let(:held) { { first_name: "TESTFIRST", last_name: "TESTLAST", date_of_birth: "19800101" } }

  # Comparing the person is the caller's, so the identification here answers only what Finding
  # asks of it: whether the answer is about someone else.
  let(:identified) { Struct.new(:mismatched?) }

  def line(status, code = nil)
    EdiGem::Benefit.new(status: status, status_code: code, service_types: ["30"])
  end

  def refusal(level, code)
    EdiGem::Rejection.new(level: level, code: code)
  end

  # What a check finds of an answer on the day.
  def checked(benefits: [], rejections: [], mismatched: false, **response)
    people = [EdiGem::Person.new(role: :subscriber, **held)]
    answer = EdiGem::Response.new(benefits: benefits, rejections: rejections, people: people, **response)
    described_class.of_check(answer, identified.new(mismatched), on: day)
  end

  describe "a check's" do
    {
      "covered WHEN an active line covers the day" => [{ benefits: [:active, "1"] }, :covered, "1"],
      "not_covered WHEN the line is inactive" => [{ benefits: [:inactive, "6"] }, :not_covered, "6"],
      "not_covered WHEN the line says not covered" => [{ benefits: [:non_covered, "I"] }, :not_covered, "I"],
      "no_answer WHEN the payer can't process" => [{ benefits: [:cannot_process, "V"] }, :no_answer, "V"]
    }.each do |example, (given, name, code)|
      it "is #{example}" do
        finding = checked(benefits: [line(*given[:benefits])])

        expect([finding.name, finding.code]).to eq [name, code]
      end
    end

    it "is no_answer WHEN the payer answered with no lines and no refusal" do
      expect(checked(settled: true, handle: "h")).to have_attributes(name: :no_answer, code: nil)
    end

    it "is someone_else WHEN the answer is about another person, however it says they are covered" do
      expect(checked(benefits: [line(:active, "1")], mismatched: true)).to be_someone_else
    end

    {
      date_of_birth_mismatch: :held_differently, name_mismatch: :held_differently,
      member_id_invalid: :not_on_this_id, subscriber_not_found: :not_on_this_id,
      patient_not_found: :not_on_this_id, duplicate_subscriber: :not_on_this_id,
      subscriber_not_in_plan: :not_on_this_id,
      required_data_missing: :our_fault, input_errors: :our_fault, invalid_date_of_service: :our_fault,
      date_out_of_range: :our_fault, date_of_death_conflict: :not_covered
    }.each do |reason, name|
      it "is #{name} WHEN the payer refuses the person as #{reason}" do
        finding = checked(rejections: [refusal(:subscriber, reason)])

        expect([finding.name, finding.code]).to eq [name, reason]
      end
    end

    it "is held_differently WHEN the dependent's birth date is refused" do
      expect(checked(rejections: [refusal(:dependent, :date_of_birth_mismatch)]))
        .to be_held_differently
    end

    it "is provider_refused WHEN the payer refuses our provider" do
      finding = checked(rejections: [refusal(:provider, :provider_not_on_file)])

      expect([finding.name, finding.code]).to eq %i[provider_refused provider_not_on_file]
    end

    it "is our_fault WHEN our request is refused at the envelope" do
      expect(checked(rejections: [refusal(:envelope, :input_errors)])).to be_our_fault
    end

    {
      "payer_down WHEN the payer can't answer right now" => [%i[payer payer_unavailable], :payer_down],
      "payer_not_connected WHEN Stedi couldn't connect to the payer" => [%i[payer invalid_participant],
                                                                         :payer_not_connected],
      "our_fault WHEN the payer refuses our setup" => [%i[payer authorization_restricted], :our_fault],
      "no_answer WHEN the payer refuses for another reason" => [%i[payer invalid_date_of_service], :no_answer]
    }.each do |example, (refused, name)|
      it "names the payer's silence #{example}" do
        finding = checked(rejections: [refusal(*refused)])

        expect([finding.name, finding.code]).to eq [name, refused.last]
      end
    end

    it "is our_fault WHEN the payer says not to send the request again" do
      not_to_resend = EdiGem::Rejection.new(level: :payer, code: :payer_unavailable, followup: "C")

      expect(checked(rejections: [not_to_resend])).to have_attributes(name: :our_fault, code: :payer_unavailable)
    end

    it "is payer_down WHEN Stedi couldn't connect but the payer also can't answer right now" do
      expect(checked(rejections: [refusal(:payer, :invalid_participant), refusal(:payer, :payer_unavailable)]))
        .to be_payer_down
    end

    it "is pending WHEN the answer hasn't arrived" do
      expect(checked(handle: "h")).to be_pending
    end
  end

  # A caller that records one word reads inactive? beside the name.
  describe "a check's line" do
    it "is inactive WHEN the line says inactive" do
      expect(checked(benefits: [line(:inactive, "6")])).to be_inactive
    end

    it "is inactive WHEN the plan's dates ended before the day, whatever the line's code says" do
      ended = EdiGem::Benefit.new(status: :active, status_code: "1", service_types: ["30"], ends_on: "20260430")

      expect(checked(benefits: [ended])).to have_attributes(name: :not_covered, inactive?: true)
    end

    it "is not inactive WHEN the line says not covered (I)" do
      expect(checked(benefits: [line(:non_covered, "I")])).to_not be_inactive
    end

    it "is none WHEN the state decided, though status lines came with it" do
      finding = checked(benefits: [line(:inactive, "6")], rejections: [refusal(:subscriber, :member_id_invalid)])

      expect([finding.name, finding.inactive?]).to eq [:not_on_this_id, false]
    end

    it "is none WHEN the answer is about someone else" do
      expect(checked(benefits: [line(:inactive, "6")], mismatched: true)).to_not be_inactive
    end

    it "is none WHEN the payer is silent, though it named a code" do
      finding = checked(rejections: [refusal(:payer, :payer_unavailable)])

      expect([finding.code, finding.inactive?]).to eq [:payer_unavailable, false]
    end
  end

  describe "a discovery's that found no plan" do
    def searched(rejections: [], **response) = EdiGem::Response.new(benefits: [], rejections: rejections, **response)

    def finding_of(answer) = described_class.of_search(answer)

    # A discovery with plans is read plan by plan (Finding.of_plan), by the caller who chose them.
    {
      "nothing_found WHEN the payer matched nobody" => [[], :nothing_found],
      "nothing_found WHEN the subscriber was not found" => [[%i[subscriber subscriber_not_found]], :nothing_found],
      "provider_refused WHEN the payer refused our provider" => [[%i[provider provider_not_on_file]],
                                                                 :provider_refused],
      "our_fault WHEN the request was refused" => [[%i[envelope malformed_request]], :our_fault],
      "our_fault WHEN what we sent was refused" => [[%i[subscriber required_data_missing]], :our_fault],
      "payer_down WHEN the payer can't answer right now" => [[%i[payer payer_unavailable]], :payer_down]
    }.each do |example, (refused, name)|
      it "is #{example}" do
        answer = searched(rejections: refused.map { |args| refusal(*args) }, settled: true, handle: "h")

        expect(finding_of(answer).name).to eq name
      end
    end

    it "is pending WHEN the answer has not arrived" do
      expect(finding_of(searched(handle: "discovery-0001"))).to be_pending
    end

    # A source can give the state with no refusal behind it.
    { payer_silent: :no_answer, rejected: :our_fault }.each do |state, name|
      it "is #{name} with no code WHEN the source gave the state #{state} and no refusal" do
        expect(finding_of(EdiGem::Response.new(state: state))).to have_attributes(name: name, code: nil)
      end
    end
  end

  describe "a discovery plan's" do
    def found(*benefits, rejections: [])
      described_class.of_plan(EdiGem::FoundPlan.new(benefits: benefits, people: [], rejections: rejections), on: day)
    end

    it "is covered WHEN its line is active" do
      expect(found(line(:active, "1"))).to have_attributes(name: :covered, code: "1")
    end

    it "is not_covered WHEN its line is inactive" do
      expect(found(line(:inactive, "6"))).to be_not_covered
    end

    it "is no_answer WHEN no line decides" do
      expect(found).to be_no_answer
    end

    it "is provider_refused WHEN no line decides and its payer refused our provider" do
      expect(found(rejections: [refusal(:provider, :provider_not_on_file)]))
        .to have_attributes(name: :provider_refused, code: :provider_not_on_file)
    end

    it "is covered WHEN its line is active, though its payer refused our provider" do
      expect(found(line(:active, "1"), rejections: [refusal(:provider, :provider_not_on_file)])).to be_covered
    end
  end

  it "inspects as its name, with its code when it has one" do
    expect([described_class.new(:pending).inspect, described_class.new(:covered, code: "1").inspect])
      .to eq ["#<EdiGem::Finding pending>", "#<EdiGem::Finding covered code=1>"]
  end

  it "is no name outside the list" do
    expect { described_class.new(:lapsed) }.to raise_error(ArgumentError)
  end
end
