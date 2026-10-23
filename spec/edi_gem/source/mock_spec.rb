# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Stedi answered from code. The person's last name picks the answer; every value is made up.
RSpec.describe EdiGem::Source::Mock do
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic") }
  let(:archive_dir) { Dir.mktmpdir }
  let(:stedi) { CannedSource::Transport.new([canned("stedi_271_active_coverage")]) }
  let(:payers) { %w[11111 22222] }
  let(:options) { {} }
  let(:source) do
    described_class.new(
      api_key: "test_key", transport: stedi, payers: payers, **options,
      archive: EdiGem::Archive::Local.new(template: "#{archive_dir}/$CLEARINGHOUSE/$FEATURE/$DIRECTION")
    )
  end
  let(:archive) { { name: "mock-spec" } }

  before { allow(Kernel).to receive(:sleep) }
  after { FileUtils.rm_rf(archive_dir) }

  def subscriber(last_name, first_name: "Pat", member_id: nil)
    EdiGem::Subscriber.new(first_name: first_name, last_name: last_name, date_of_birth: "19800101",
                           member_id: member_id)
  end

  def discovery(last_name, first_name: "Pat")
    inquiry = EdiGem::Inquiry::Discovery.new(subscriber: subscriber(last_name, first_name: first_name),
                                             provider: provider, as_of: Date.new(2026, 10, 20))
    source.discovery(inquiry, archive: archive)
  end

  def check(last_name, payer_code: "11111")
    inquiry = EdiGem::Inquiry::Eligibility.new(payer_code: payer_code, provider: provider,
                                               subscriber: subscriber(last_name, member_id: "MOCKID0001"))
    source.eligibility(inquiry, archive: archive)
  end

  def found(response)
    response.benefits.select(&:line?).map { |line| [line.payer_code, line.status] }.uniq
  end

  def fault_kind
    yield
  rescue EdiGem::Fault => error
    error.kind
  end

  it_behaves_like "a source" do
    let(:inquiry) do
      EdiGem::Inquiry::Eligibility.new(payer_code: "11111", provider: provider, subscriber: subscriber("Active"))
    end
  end

  describe "building it" do
    it "is built by name" do
      expect(EdiGem::Source.for(:mock, api_key: "test_key", archive: nil)).to be_a(described_class)
    end

    it "is Stedi, for everything it does not answer itself" do
      expect(described_class.new(api_key: "test_key", archive: nil)).to be_a(EdiGem::Source::Stedi)
    end
  end

  describe "everything but discovery" do
    it "sends a check to Stedi" do
      check("Active")

      expect(stedi.paths).to eq([EdiGem::Policy.for(:stedi).path_for(:eligibility)])
    end

    it "never sends a discovery to Stedi" do
      discovery("Active")

      expect(stedi.paths).to be_empty
    end
  end

  describe "a discovery" do
    it "finds an active plan for every payer it was given" do
      expect(found(discovery("Active"))).to eq([["11111", :active], ["22222", :active]])
    end

    it "asks for the payers on every discovery, when given something to ask" do
      options = { payers: -> { %w[33333] } }
      mock = described_class.new(api_key: "test_key", archive: nil, **options)
      inquiry = EdiGem::Inquiry::Discovery.new(subscriber: subscriber("Active"), provider: provider,
                                               as_of: Date.new(2026, 10, 20))

      expect(found(mock.discovery(inquiry))).to eq([["33333", :active]])
    end

    it "finds plans at its own made-up payer when given none" do
      mock = described_class.new(api_key: "test_key", archive: nil)
      inquiry = EdiGem::Inquiry::Discovery.new(subscriber: subscriber("Active"), provider: provider,
                                               as_of: Date.new(2026, 10, 20))

      expect(found(mock.discovery(inquiry))).to eq([["MOCKPAYER", :active]])
    end

    it "names each plan, as Stedi does" do
      expect(discovery("Active").benefits.filter_map(&:plan_name).uniq).to eq(["MOCK PLAN 11111", "MOCK PLAN 22222"])
    end

    it "reads the last name without regard to case, spaces or punctuation" do
      expect(found(discovery(" ac-tive"))).to eq([["11111", :active], ["22222", :active]])
    end

    it "is complete for an active plan" do
      expect(discovery("Active").state).to eq(:complete)
    end

    it "is labelled production, as Stedi labels every discovery" do
      expect(discovery("Active").application_mode).to eq("production")
    end

    it "finds the plans inactive" do
      expect(found(discovery("Inactive"))).to eq([["11111", :inactive], ["22222", :inactive]])
    end

    it "finds plans that name no birth date" do
      birth_dates = discovery("Unverified").found_plans.map { |plan| plan.person.date_of_birth }

      expect(birth_dates).to eq([nil, nil])
    end

    it "finds plans for someone with another first name and birth date" do
      people = discovery("OtherPerson").found_plans.map do |plan|
        plan.person.identity.values_at(:first_name, :date_of_birth)
      end

      expect(people.uniq).to eq([["ALEX", EdiGem::Source::Mock::Plans::MISMATCHED_BIRTH_DATE]])
    end

    it "finds a plan for a payer it was not given" do
      expect(found(discovery("OtherPayer"))).to eq([[EdiGem::Source::Mock::Plans::OTHER_PAYER, :active]])
    end

    it "finds nothing for any other last name" do
      expect(discovery("Smith").state).to eq(:no_coverage)
    end

    it "is rejected, by the provider's refusal, for the Refused last name" do
      response = discovery("Refused")

      expect([response.state, response.provider_refusals.size]).to eq([:rejected, 1])
    end

    it "is the payer's silence, not the provider's refusal, for the NoAnswer last name" do
      response = discovery("NoAnswer")

      expect([response.state, response.provider_refusals]).to eq([:payer_silent, []])
    end

    it "does not identify the person for the NotFound last name" do
      expect(discovery("NotFound").state).to eq(:not_identified)
    end

    it "archives the request and the answer, as for Stedi" do
      expect(discovery("Active").stored.request_uri).to start_with("file://")
    end

    it "recovers the question from the archived request, as Stedi does" do
      question = source.archived_question(discovery("Active").stored.request_uri)

      expect([question.person.to_h, question.as_of])
        .to eq([{ first_name: "PAT", last_name: "ACTIVE", date_of_birth: Date.new(1980, 1, 1) },
                Date.new(2026, 10, 20)])
    end

    it "files them under Stedi" do
      expect(discovery("Active").stored.request_uri).to include("/stedi/")
    end

    it "finds an active and an inactive plan at every payer" do
      expect(found(discovery("Mixed")))
        .to eq([["11111", :active], ["11111", :inactive], ["22222", :active], ["22222", :inactive]])
    end

    it "finds each plan under its own member ID" do
      expect(discovery("Mixed").found_plans.map(&:member_id).uniq.size).to eq(4)
    end

    { "ActiveInvestigation" => :active, "InactiveUpdate" => :inactive, "InactiveInvestigation" => :inactive }
      .each do |last_name, status|
        it "reads #{last_name}'s EB01 as #{status}" do
          expect(found(discovery(last_name)).first).to eq(["11111", status])
        end
      end

    it "finds active plans dated to end before today" do
      ends = discovery("Ended").benefits.filter_map(&:ends_on).uniq

      expect(ends).to all(be < Date.today.strftime("%Y%m%d"))
    end

    it "finds active plans dated to begin after today" do
      begins = discovery("NotStarted").benefits.filter_map(&:begins_on).uniq

      expect(begins).to all(be > Date.today.strftime("%Y%m%d"))
    end

    it "finds plans that cover only dental" do
      expect(discovery("Dental").benefits.select(&:line?).flat_map { |line| line[:service_types] }.uniq).to eq(["35"])
    end

    it "finds an MCO naming the state's Medicaid as its primary payer" do
      expect(discovery("MedicaidMco").benefits.filter_map(&:primary_payer_code).uniq)
        .to eq([EdiGem::Source::Mock::Plans::MEDICAID_PAYER])
    end

    it "finds the Medicaid item beside the MCO, with the state's id for the person" do
      medicaid = discovery("MedicaidMco").found_plans.last

      expect([medicaid.payer_code, medicaid[:state_insurance_id]])
        .to eq([EdiGem::Source::Mock::Plans::MEDICAID_PAYER, EdiGem::Source::Mock::Plans::MEDICAID_ID])
    end

    it "is confident, with a reason, WHEN asked to be" do
      expect(discovery("Confident").benefits.filter_map { |line| line[:confidence_reason] }.uniq)
        .to eq(["Name, date of birth and state matched"])
    end

    it "asks for review otherwise" do
      expect(discovery("Active").benefits.filter_map { |line| line[:confidence] }.uniq).to eq(["REVIEW_NEEDED"])
    end

    it "finds plans with an error beside them" do
      response = discovery("FoundWithError")

      expect([found(response).size, response.rejections.map(&:code)]).to eq([2, [:payer_unavailable]])
    end

    it "finds plans with a rejection for part of the question, for the Partial last name" do
      expect(discovery("Partial").state).to eq(:partial)
    end

    it "answers with any AAA code Stedi publishes, in the loop it belongs to" do
      expect(discovery("Aaa75").rejections.first)
        .to have_attributes(code: :subscriber_not_found, location: "Loop 2100C")
    end

    { "Aaa64" => "Loop 2100D", "Aaa79" => "Loop 2100B", "Aaa04" => "Loop 2100A" }.each do |last_name, location|
      it "puts #{last_name} in #{location}" do
        expect(discovery(last_name).rejections.first.location).to eq(location)
      end
    end

    it "finds nothing for an AAA code Stedi does not publish" do
      expect(discovery("Aaa99").rejections).to be_empty
    end
  end

  describe "the person as a payer spells them" do
    it "uppercases, drops accents and cuts a long first name short, keeping the birth date" do
      person = discovery("Spélled", first_name: "Maximiliano").found_plans.first.person

      expect(person.identity.values).to eq(%w[MAXIMILI SPELLED 19800101])
    end

    it "is still the person asked about" do
      plan = discovery("Spélled", first_name: "Maximiliano").found_plans.first

      expect(plan.identify({ first_name: "Maximiliano", last_name: "Spélled", date_of_birth: "19800101" }).result)
        .to be_matched
    end
  end

  describe "the patient as a dependent" do
    let(:plan) { discovery("Dependent").found_plans.first }

    it "names the patient as the dependent, a child (19), as Stedi does" do
      expect(plan.person).to have_attributes(role: :dependent, first_name: "PAT", relationship_code: "19")
    end

    it "names someone else as the subscriber, the policyholder (18)" do
      expect(plan.subscriber_person).to have_attributes(first_name: "JORDAN", relationship_code: "18")
    end
  end

  describe "the patient as the policyholder" do
    let(:plan) { discovery("Active").found_plans.first }

    it "names the subscriber as the policyholder (18)" do
      expect(plan.person).to have_attributes(role: :subscriber, relationship_code: "18")
    end

    it "sends the address the payer holds, as Stedi does" do
      expect(plan.person.address.to_h).to eq(line1: "1 MOCK WAY", city: "MOCKVILLE", state: "ZZ", postal_code: "00000")
    end
  end

  describe "a pending discovery" do
    def resolved(last_name)
      source.resolve(discovery(last_name).handle, archive: archive)
    end

    it "is pending at first" do
      expect(discovery("Pending").state).to eq(:pending)
    end

    it "names the scenario in its handle, never the person" do
      expect(discovery("Pending").handle).to match(/\Amock-pending-[0-9a-f-]{36}\z/)
    end

    it "is complete, active, WHEN collected" do
      response = resolved("Pending")

      expect([response.state, found(response).map(&:last).uniq]).to eq([:complete, [:active]])
    end

    it "finds the plans for the person it was about" do
      expect(resolved("Pending").found_plans.map { |plan| plan.person.last_name }.uniq).to eq(["PENDING"])
    end

    it "finds the person through `people` when given it" do
      person = EdiGem::Subscriber.new(first_name: "Pat", last_name: "Pending", date_of_birth: "19800101")
      options[:people] = ->(_discovery_id) { person }

      expect(resolved("Pending").found_plans.map { |plan| plan.person.last_name }.uniq).to eq(["Pending"])
    end

    it "has nothing to collect WHEN `people` knows no one by that id" do
      options[:people] = ->(_discovery_id) {}

      expect(fault_kind { resolved("Pending") }).to eq(:malformed_request)
    end

    it "is still pending WHEN collected" do
      expect(resolved("StillPending").state).to eq(:pending)
    end

    it "fails WHEN collected, as a discovery Stedi could not complete" do
      expect(fault_kind { resolved("PendingError") }).to eq(:vendor_error)
    end

    it "is gone WHEN collected, as one Stedi no longer keeps" do
      expect(fault_kind { resolved("Expired") }).to eq(:malformed_request)
    end

    it "has no discovery to collect by an id it never gave" do
      expect(fault_kind { source.resolve("unknown", archive: archive) }).to eq(:malformed_request)
    end
  end

  describe "a discovery Stedi could not complete" do
    it "is a vendor_error fault" do
      expect(fault_kind { discovery("Error") }).to eq(:vendor_error)
    end
  end

  describe "a discovery Stedi refuses over HTTP" do
    { "Invalid" => :malformed_request, "Forbidden" => :not_authorized, "InFlight" => :already_in_flight,
      "KeyReused" => :malformed_request, "Throttled" => :rate_limited, "ServerError" => :vendor_unavailable,
      "Unavailable" => :vendor_unavailable, "GatewayTimeout" => :vendor_unavailable, "Timeout" => :timeout }
      .each do |last_name, kind|
        it "raises #{kind} for #{last_name}, as the gem makes of its status" do
          expect(fault_kind { discovery(last_name) }).to eq(kind)
        end
      end

    it "retries a rate limit as the gem does, and answers the next try" do
      expect(found(discovery("ThrottledOnce"))).to eq([["11111", :active], ["22222", :active]])
    end

    it "asks to wait a second before an identical request still in flight" do
      expect { discovery("InFlight") }.to raise_error(EdiGem::Fault) { |fault| expect(fault.retry_after).to eq(1) }
    end

    it "refuses a request without the provider's NPI" do
      client = described_class::Client.new(answers: described_class::Answers.new)
      request = Net::HTTP::Post.new("/insurance-discovery").tap { |post| post.body = JSON.generate({}) }

      expect(client.request(request).code).to eq("400")
    end
  end
end
