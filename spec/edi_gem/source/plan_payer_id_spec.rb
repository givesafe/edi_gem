# frozen_string_literal: true

require "tmpdir"

# A discovered plan's payer, as the clearinghouse names it: asked of the source's own directory,
# and only when a caller wants it (the app's ShownPlans searched the directory per active plan).
# The payers and people here are made up.
RSpec.describe "A discovered plan's payer ID" do
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC") }
  let(:subscriber) { EdiGem::Subscriber.new(first_name: "Testfirst", last_name: "Testlast", date_of_birth: "19800101") }
  let(:inquiry) { EdiGem::Inquiry::Discovery.new(subscriber: subscriber, provider: provider, as_of: "20260901") }
  let(:directory_answer) do
    canned_body({ "items" => [{ "payer" => { "stediId" => "stedi-77027", "primaryPayerId" => "99999",
                                             "displayName" => "EXAMPLE PAYER", "aliases" => ["77027"] } }] })
  end

  # The first search fails as a transport would fail it, the second is answered.
  let(:failing_once) do
    Class.new(CannedSource::Transport) do
      def perform(path:, **)
        return super unless @paths.empty?

        @paths << path
        raise EdiGem::Fault.new(kind: :timeout, source: :stedi, path: path)
      end
    end
  end

  it "is the directory's payer ID for the plan's payer code" do
    source, = stedi_answering(canned("stedi_discovery_complete"), directory_answer)
    plan = source.discovery(inquiry).medical_plans.fetch(0)

    expect([plan.payer_code, plan.payer_id]).to eq(%w[77027 99999])
  end

  it "asks the directory only when asked, and once" do
    source, transport = stedi_answering(canned("stedi_discovery_complete"), directory_answer)
    plan = source.discovery(inquiry).medical_plans.fetch(0)
    asked_before = transport.paths.size
    2.times { plan.payer_id }

    expect([asked_before, transport.paths.size]).to eq([1, 2])
  end

  it "is nil, asked once, WHEN no single payer in the directory answers to the code" do
    source, transport = stedi_answering(canned("stedi_discovery_complete"), canned_body({ "items" => [] }))
    plan = source.discovery(inquiry).medical_plans.fetch(0)
    2.times { plan.payer_id }

    expect([plan.payer_id, transport.paths.size]).to eq([nil, 2])
  end

  it "is one directory request for every plan with that payer code asked twice, for the source's lifetime" do
    source, transport = stedi_answering(canned("stedi_discovery_complete"), directory_answer)
    answer = source.discovery(inquiry)
    ids = [answer.medical_plans.fetch(0).payer_id, answer.medical_plans.fetch(0).payer_id]

    expect([ids, transport.paths.size]).to eq([%w[99999 99999], 2])
  end

  it "is one directory request for the same payer code across two answers from one source" do
    discovery = canned("stedi_discovery_complete")
    source, transport = stedi_answering(discovery, directory_answer, discovery)
    first = source.discovery(inquiry).medical_plans.fetch(0).payer_id
    second = source.discovery(inquiry).medical_plans.fetch(0).payer_id

    expect([first, second, transport.paths.size]).to eq(["99999", "99999", 3])
  end

  context "WHEN a search fails" do
    let(:transport) { failing_once.new([directory_answer]) }
    let(:source) { EdiGem::Source::Stedi.new(api_key: "test_key", transport: transport, archive: nil) }

    it "raises it" do
      expect { source.payer_id_for("77027") }.to raise_error(EdiGem::Fault) { |fault| expect(fault.kind).to eq :timeout }
    end

    it "remembers nothing, and searches again when asked again" do
      expect { source.payer_id_for("77027") }.to raise_error(EdiGem::Fault)

      expect([source.payer_id_for("77027"), transport.paths.size]).to eq(["99999", 2])
    end
  end

  describe "an answer read again from the archive" do
    # The directory lives only inside mktmpdir's block, which the around hook wraps the example in;
    # a `let` cannot reach a block's argument, so the example reads it from an instance variable.
    # rubocop:disable RSpec/InstanceVariable
    around do |example|
      Dir.mktmpdir("edi-archive") { |dir| @root = dir and example.run }
    end

    let(:archive) { EdiGem::Archive::Local.new(template: "#{@root}/$FEATURE/$DIRECTION") }
    # rubocop:enable RSpec/InstanceVariable

    it "asks the directory nothing for its addresses" do
      source, transport = stedi_answering(canned("stedi_discovery_complete"), archive: archive)
      kept = source.discovery(inquiry, archive: { name: "discovery-1" })

      plans = source.archived(kept.stored.response_uri, kind: :discovery).medical_plans

      expect([plans.map { |plan| plan.person.address.postal_code }, transport.paths.size]).to eq([["00000"], 1])
    end
  end

  it "is Stedi's for the mock, which asks Stedi's directory" do
    listed = canned_body({ "items" => [{ "payer" => { "stediId" => "stedi-11111", "primaryPayerId" => "11111" } }] })
    transport = CannedSource::Transport.new([listed])
    source = EdiGem::Source::Mock.new(api_key: "test_key", transport: transport, payers: ["11111"], archive: nil)
    allow(Kernel).to receive(:sleep)
    active = EdiGem::Subscriber.new(first_name: "Pat", last_name: "Active", date_of_birth: "19800101")
    plan = source.discovery(EdiGem::Inquiry::Discovery.new(subscriber: active, provider: provider, as_of: "20261020"))
                 .medical_plans.fetch(0)

    expect([plan.payer_code, plan.payer_id]).to eq(%w[11111 11111])
  end

  it "is nil on an answer no source read" do
    plan = EdiGem::Response.new(found_plans: [EdiGem::FoundPlan.new(benefits: [EdiGem::Benefit.new(status: :active)],
                                                                    people: [])]).medical_plans.fetch(0)

    expect(plan.payer_id).to be_nil
  end
end
