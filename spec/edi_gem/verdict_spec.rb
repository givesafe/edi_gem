# frozen_string_literal: true

RSpec.describe EdiGem::Verdict do
  let(:today) { Date.new(2026, 10, 21) }
  let(:asked) { { first_name: "A", last_name: "B", date_of_birth: Date.new(1980, 1, 1) } }

  def benefit(status, **fields)
    EdiGem::Benefit.new(status: status, benefit_type: nil, **fields)
  end

  def rejection(level, code = :member_id_invalid)
    EdiGem::Rejection.new(level: level, code: code)
  end

  def response(benefits: [], rejections: [], **options)
    EdiGem::Response.new(benefits: benefits, rejections: rejections, **options)
  end

  describe "CheckedPlan#verdict, a check's" do
    let(:verdict) { answer.checked_plan(identification: answer.identify(asked)).verdict(on: today) }

    {
      "complete with an active benefit" => [{ benefits: [:active] }, :active],
      "inactive benefits" => [{ benefits: [:inactive] }, :inactive],
      "one service type active and another inactive" => [{ benefits: %i[inactive active] }, :active],
      "a verdict line that says the person is not covered" => [{ benefits: [:non_covered] }, :not_covered],
      "a line that says it cannot process, which is no denial" => [{ benefits: [:cannot_process] }, :unanswered]
    }.each do |said, (parts, expected)|
      it "is #{expected} for #{said}" do
        answer = response(benefits: parts[:benefits].map { |status| benefit(status) })

        expect(answer.checked_plan(identification: answer.identify(asked)).verdict(on: today)).to eq(expected)
      end
    end

    context "WHEN the answer is partial with an active benefit" do
      let(:answer) { response(benefits: [benefit(:active)], rejections: [rejection(:dependent, :other)]) }

      it("is active") { expect(verdict).to eq(:active) }
    end

    context "WHEN the payer rejected the question but a benefit came with it" do
      let(:answer) { response(benefits: [benefit(:active)], rejections: [rejection(:payer)]) }

      it("is unanswered, because the payer is silent") { expect(verdict).to eq(:unanswered) }
    end

    # Coverage's two-part test: within the plan's dates, and a line on 30 says active.
    context "WHEN the plan's dates ended before the day asked about" do
      let(:answer) { response(benefits: [benefit(:active, status_code: "1", ends_on: "20260930")]) }

      it("is inactive, whatever the line's code says") { expect(verdict).to eq(:inactive) }
    end

    context "WHEN only another service type is active" do
      let(:answer) { response(benefits: [benefit(:active, service_types: ["35"])]) }

      it("is unanswered, because nothing was said about the plan") { expect(verdict).to eq(:unanswered) }
    end

    context "WHEN the plan carries a term on 30 and no status line" do
      let(:answer) { response(benefits: [EdiGem::Benefit.new(benefit_type: :co_payment, service_types: ["30"])]) }

      it("is active, because the term implies coverage") { expect(verdict).to eq(:active) }
    end

    context "WHEN the answer holds only benefit detail" do
      let(:answer) { response(benefits: [EdiGem::Benefit.new(status: nil, benefit_type: :deductible)]) }

      it("is unanswered") { expect(verdict).to eq(:unanswered) }
    end

    context "WHEN the payer found no coverage" do
      let(:answer) { response(settled: true, handle: "h") }

      it("is not_covered") { expect(verdict).to eq(:not_covered) }
    end

    context "WHEN the payer could not identify the subscriber" do
      let(:answer) { response(rejections: [rejection(:subscriber)]) }

      it("is not_covered") { expect(verdict).to eq(:not_covered) }
    end

    context "WHEN the payer found the ID but not the birth date (AAA 71)" do
      let(:answer) { response(rejections: [rejection(:subscriber, :date_of_birth_mismatch)]) }

      it "is unanswered, naming the payer's reason: the person may still be covered" do
        expect([verdict, answer.error_code]).to eq([:unanswered, "date_of_birth_mismatch"])
      end

      it "is unanswered with no identification given, by the payer's refusal alone" do
        expect(answer.checked_plan.verdict(on: today)).to eq(:unanswered)
      end
    end

    context "WHEN the payer found the ID but not the dependent's name (AAA 65)" do
      let(:answer) { response(rejections: [rejection(:dependent, :name_mismatch)]) }

      it("is unanswered") { expect(verdict).to eq(:unanswered) }
    end

    context "WHEN the payer answered about someone else, by our comparison" do
      let(:answer) do
        response(benefits: [benefit(:active)],
                 people: [EdiGem::Person.new(role: :subscriber, first_name: "C", last_name: "B",
                                             date_of_birth: "19820505")])
      end

      it("is unanswered, never that person's active coverage") { expect(verdict).to eq(:unanswered) }

      it "is that coverage when no identification is given, since nobody was compared" do
        expect(answer.checked_plan.verdict(on: today)).to eq(:active)
      end
    end

    context "WHEN the payer refused our provider" do
      let(:answer) { response(rejections: [rejection(:provider, :provider_not_enrolled_on_date)]) }

      it("is provider_refused") { expect(verdict).to eq(:provider_refused) }
    end

    context "WHEN the payer did not answer" do
      let(:answer) { response(rejections: [rejection(:payer, :payer_unavailable)]) }

      it "is unanswered with the rejection code" do
        expect([verdict, answer.error_code]).to eq([:unanswered, "payer_unavailable"])
      end
    end

    context "WHEN our own request was refused" do
      let(:answer) { response(rejections: [rejection(:envelope, :malformed_request)]) }

      it "is unanswered with the rejection code" do
        expect([verdict, answer.error_code]).to eq([:unanswered, "malformed_request"])
      end
    end

    context "WHEN the answer has not arrived" do
      let(:answer) { response(handle: "handle-1") }

      it("is pending") { expect(verdict).to eq(:pending) }
    end

    it "is one of the verdict names" do
      expect(described_class::NAMES).to include(response.checked_plan.verdict(on: today))
    end
  end

  describe "CheckedPlan#verdict_code" do
    let(:line) { benefit(:active, status_code: "1") }

    it "is the code of the line that decided an answered check" do
      answer = response(benefits: [line])

      expect(answer.checked_plan(identification: answer.identify(asked)).verdict_code(on: today)).to eq("1")
    end

    it "is nil WHEN the state decided, though status lines came with it" do
      answer = response(benefits: [line], rejections: [rejection(:subscriber)])

      plan = answer.checked_plan(identification: answer.identify(asked))

      expect([plan.verdict(on: today), plan.verdict_code(on: today)]).to eq([:not_covered, nil])
    end

    it "is nil WHEN the answer is about someone else" do
      someone = EdiGem::Person.new(role: :subscriber, first_name: "C", last_name: "B", date_of_birth: "19820505")
      answer = response(benefits: [line], people: [someone])

      expect(answer.checked_plan(identification: answer.identify(asked)).verdict_code(on: today)).to be_nil
    end
  end

  describe "Response#error_code" do
    it "is nil when nothing was refused" do
      expect(response.error_code).to be_nil
    end

    it "is a code the codec did not name as its raw string" do
      expect(response(rejections: [rejection(:payer, "99")]).error_code).to eq("99")
    end
  end

  describe "Response#discovery_verdict" do
    def plan(*statuses)
      EdiGem::FoundPlan.new(benefits: statuses.map { |status| benefit(status, service_types: ["30"]) }, people: [])
    end

    def discovered(plans, rejections: [])
      response(benefits: plans.flat_map(&:benefits), rejections: rejections, found_plans: plans)
    end

    def verdict_of(answer) = answer.discovery_verdict(on: today, plans: answer.found_plans)

    it "is active WHEN any plan is active" do
      expect(verdict_of(discovered([plan(:inactive), plan(:active)]))).to eq(:active)
    end

    it "is inactive WHEN a plan is inactive and none active" do
      expect(verdict_of(discovered([plan(:inactive)]))).to eq(:inactive)
    end

    it "is unanswered WHEN no plan says active or inactive, since a plan we could not read is no denial" do
      expect(verdict_of(discovered([plan(:non_covered)]))).to eq(:unanswered)
    end

    it "lets a plan decide whatever refusals came with it" do
      answer = discovered([plan(:active)], rejections: [rejection(:payer, :payer_unavailable)])

      expect(verdict_of(answer)).to eq(:active)
    end

    it "is not_covered WHEN the payer matched nobody" do
      expect(verdict_of(discovered([]))).to eq(:not_covered)
    end

    it "is not_covered WHEN the subscriber was not found" do
      expect(verdict_of(discovered([], rejections: [rejection(:subscriber, :subscriber_not_found)])))
        .to eq(:not_covered)
    end

    # The caller passes only the medical plans; a dental plan left out leaves a complete answer
    # with nothing medical in it.
    it "is not_covered WHEN the plans passed leave out every plan found" do
      answer = discovered([plan(:active)])

      expect(answer.discovery_verdict(on: today, plans: [])).to eq(:not_covered)
    end

    it "is provider_refused WHEN the payer refused our provider and found nothing" do
      expect(verdict_of(discovered([], rejections: [rejection(:provider, :provider_not_on_file)])))
        .to eq(:provider_refused)
    end

    it "is unanswered WHEN the request was refused and found nothing" do
      expect(verdict_of(discovered([], rejections: [rejection(:envelope, :malformed_request)]))).to eq(:unanswered)
    end

    it "is unanswered WHEN the payer did not answer and found nothing" do
      expect(verdict_of(discovered([], rejections: [rejection(:payer, :payer_unavailable)]))).to eq(:unanswered)
    end

    it "is pending WHEN the answer has not arrived" do
      answer = response(handle: "discovery-0001")

      expect(answer.discovery_verdict(on: today)).to eq(:pending)
    end
  end
end
