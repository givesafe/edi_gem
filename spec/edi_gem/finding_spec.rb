# frozen_string_literal: true

# What an answer established, one finding per row of the table on EdiGem::Finding. Every value here
# is made up.
RSpec.describe EdiGem::Finding do
  let(:day) { Date.new(2026, 6, 1) }
  let(:asked) { { first_name: "Testfirst", last_name: "Testlast", date_of_birth: Date.new(1980, 1, 1) } }
  let(:held) { { first_name: "TESTFIRST", last_name: "TESTLAST", date_of_birth: "19800101" } }

  def line(status, code = nil)
    EdiGem::Benefit.new(status: status, status_code: code, service_types: ["30"])
  end

  def refusal(level, code)
    EdiGem::Rejection.new(level: level, code: code)
  end

  def checked(benefits: [], rejections: [], people: [EdiGem::Person.new(role: :subscriber, **held)], **response)
    answer = EdiGem::Response.new(benefits: benefits, rejections: rejections, people: people, **response)
    answer.checked_plan(identification: answer.identify(asked))
  end

  describe "a check's" do
    {
      "covered WHEN an active line covers the day" => [{ benefits: [:active, "1"] }, :covered, "1"],
      "not_covered WHEN the line is inactive" => [{ benefits: [:inactive, "6"] }, :not_covered, "6"],
      "not_covered WHEN the line says not covered" => [{ benefits: [:non_covered, "I"] }, :not_covered, "I"],
      "no_answer WHEN the payer can't process" => [{ benefits: [:cannot_process, "V"] }, :no_answer, "V"]
    }.each do |example, (given, name, code)|
      it "is #{example}" do
        finding = checked(benefits: [line(*given[:benefits])]).finding(on: day)

        expect([finding.name, finding.code]).to eq [name, code]
      end
    end

    it "is not_covered WHEN the payer answered with no lines" do
      expect(checked(settled: true, handle: "h").finding(on: day)).to have_attributes(name: :not_covered, code: nil)
    end

    it "is someone_else WHEN the answer is about another person, however it says they are covered" do
      other = EdiGem::Person.new(role: :subscriber, first_name: "OTHER", last_name: "PERSON", date_of_birth: "19700101")

      expect(checked(benefits: [line(:active, "1")], people: [other]).finding(on: day)).to be_someone_else
    end

    {
      date_of_birth_mismatch: :held_differently, name_mismatch: :held_differently,
      member_id_invalid: :not_on_this_id, subscriber_not_found: :not_on_this_id,
      patient_not_found: :not_on_this_id, duplicate_subscriber: :not_on_this_id
    }.each do |reason, name|
      it "is #{name} WHEN the payer refuses the person as #{reason}" do
        finding = checked(rejections: [refusal(:subscriber, reason)]).finding(on: day)

        expect([finding.name, finding.code]).to eq [name, reason]
      end
    end

    it "is held_differently WHEN the dependent's birth date is refused" do
      expect(checked(rejections: [refusal(:dependent, :date_of_birth_mismatch)]).finding(on: day))
        .to be_held_differently
    end

    it "is provider_refused WHEN the payer refuses our provider" do
      finding = checked(rejections: [refusal(:provider, :provider_not_on_file)]).finding(on: day)

      expect([finding.name, finding.code]).to eq %i[provider_refused provider_not_on_file]
    end

    it "is our_fault WHEN our request is refused at the envelope" do
      expect(checked(rejections: [refusal(:envelope, :input_errors)]).finding(on: day)).to be_our_fault
    end

    it "is no_answer WHEN the payer is silent" do
      finding = checked(rejections: [refusal(:payer, :payer_unavailable)]).finding(on: day)

      expect([finding.name, finding.code]).to eq %i[no_answer payer_unavailable]
    end

    it "is pending WHEN the answer hasn't arrived" do
      expect(checked(handle: "h").finding(on: day)).to be_pending
    end
  end

  # A caller that records one word reads inactive? and line_code beside the name.
  describe "a check's line" do
    it "is inactive WHEN the line says inactive, with its code" do
      finding = checked(benefits: [line(:inactive, "6")]).finding(on: day)

      expect([finding.inactive?, finding.line_code]).to eq [true, "6"]
    end

    it "is inactive WHEN the plan's dates ended before the day, whatever the line's code says" do
      ended = EdiGem::Benefit.new(status: :active, status_code: "1", service_types: ["30"], ends_on: "20260430")

      expect(checked(benefits: [ended]).finding(on: day)).to have_attributes(name: :not_covered, inactive?: true,
                                                                             line_code: nil)
    end

    it "is not inactive WHEN the line says not covered (I)" do
      expect(checked(benefits: [line(:non_covered, "I")]).finding(on: day)).to_not be_inactive
    end

    it "is none WHEN the state decided, though status lines came with it" do
      finding = checked(benefits: [line(:inactive, "6")], rejections: [refusal(:subscriber, :member_id_invalid)])
                .finding(on: day)

      expect([finding.name, finding.inactive?, finding.line_code]).to eq [:not_on_this_id, false, nil]
    end

    it "is none WHEN the answer is about someone else" do
      other = EdiGem::Person.new(role: :subscriber, first_name: "OTHER", last_name: "PERSON", date_of_birth: "19700101")
      finding = checked(benefits: [line(:inactive, "6")], people: [other]).finding(on: day)

      expect([finding.inactive?, finding.line_code]).to eq [false, nil]
    end

    it "is none WHEN the payer is silent, though it named a code" do
      finding = checked(rejections: [refusal(:payer, :payer_unavailable)]).finding(on: day)

      expect([finding.code, finding.line_code]).to eq [:payer_unavailable, nil]
    end
  end

  describe "a discovery's, among its plans" do
    def plan(*statuses) = EdiGem::FoundPlan.new(benefits: statuses.map { |status| line(status) }, people: [])

    def discovered(plans, rejections: [], **response)
      EdiGem::Response.new(benefits: plans.flat_map(&:benefits), rejections: rejections, found_plans: plans,
                           **response)
    end

    def finding_of(answer, plans = answer.found_plans) = answer.discovery_finding(on: day, plans: plans)

    it "is covered WHEN any plan is active" do
      expect(finding_of(discovered([plan(:inactive), plan(:active)]))).to be_covered
    end

    it "is the inactive plan's WHEN a plan is inactive and none active" do
      expect(finding_of(discovered([plan(:non_covered), plan(:inactive)])))
        .to have_attributes(name: :not_covered, inactive?: true)
    end

    it "is no_answer WHEN no plan says active or inactive, since a plan we could not read is no denial" do
      expect(finding_of(discovered([plan(:non_covered)])).name).to eq :no_answer
    end

    it "lets a plan decide whatever refusals came with it" do
      expect(finding_of(discovered([plan(:active)], rejections: [refusal(:payer, :payer_unavailable)]))).to be_covered
    end

    # The caller passes only the medical plans; a dental plan left out leaves nothing medical.
    {
      "not_covered WHEN the payer matched nobody" => [[], :not_covered],
      "not_covered WHEN the subscriber was not found" => [[%i[subscriber subscriber_not_found]], :not_covered],
      "provider_refused WHEN the payer refused our provider" => [[%i[provider provider_not_on_file]],
                                                                 :provider_refused],
      "our_fault WHEN the request was refused" => [[%i[envelope malformed_request]], :our_fault],
      "no_answer WHEN the payer did not answer" => [[%i[payer payer_unavailable]], :no_answer]
    }.each do |example, (refused, name)|
      it "is #{example} and found nothing" do
        answer = discovered([plan(:active)], rejections: refused.map { |args| refusal(*args) })

        expect(finding_of(answer, []).name).to eq name
      end
    end

    it "is pending WHEN the answer has not arrived" do
      expect(finding_of(EdiGem::Response.new(benefits: [], rejections: [], handle: "discovery-0001"))).to be_pending
    end

    # A source can give the state with no refusal behind it.
    { payer_silent: :no_answer, rejected: :our_fault }.each do |state, name|
      it "is #{name} with no code WHEN the source gave the state #{state} and no refusal" do
        expect(finding_of(EdiGem::Response.new(state: state))).to have_attributes(name: name, code: nil)
      end
    end
  end

  describe "a discovery plan's" do
    def found(*benefits) = EdiGem::FoundPlan.new(benefits: benefits, people: [])

    it "is covered WHEN its line is active" do
      expect(found(line(:active, "1")).finding(on: day)).to have_attributes(name: :covered, code: "1")
    end

    it "is not_covered WHEN its line is inactive" do
      expect(found(line(:inactive, "6")).finding(on: day)).to be_not_covered
    end

    it "is no_answer WHEN no line decides" do
      expect(found.finding(on: day)).to be_no_answer
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
