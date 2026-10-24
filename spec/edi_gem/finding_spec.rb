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

  # Verdict folds findings into one word to record. These are the folds callers can't undo from it.
  describe "beside a check's verdict" do
    other = { role: :subscriber, first_name: "OTHER", last_name: "PERSON", date_of_birth: "19700101" }
    {
      "someone_else" => [{ benefits: [[:active, "1"]], people: [other] }, :unanswered],
      "held_differently" => [{ rejections: [%i[subscriber name_mismatch]] }, :unanswered],
      "not_on_this_id" => [{ rejections: [%i[subscriber member_id_invalid]] }, :not_covered],
      "our_fault" => [{ rejections: [%i[envelope input_errors]] }, :unanswered],
      "no_answer" => [{ rejections: [%i[payer payer_unavailable]] }, :unanswered]
    }.each do |name, (given, verdict)|
      it "is #{name} where the verdict is #{verdict}" do
        plan = checked(benefits: Array(given[:benefits]).map { |args| line(*args) },
                       rejections: Array(given[:rejections]).map { |args| refusal(*args) },
                       people: [EdiGem::Person.new(**(given[:people]&.first || { role: :subscriber, **held }))])

        expect([plan.finding(on: day).name, plan.verdict(on: day)]).to eq [name.to_sym, verdict]
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

  it "is no name outside the list" do
    expect { described_class.new(:lapsed) }.to raise_error(ArgumentError)
  end
end
