# frozen_string_literal: true

require "tmpdir"

# The public calls, end to end against canned responses written from Stedi's documentation.
RSpec.describe "calling Stedi" do
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic") }
  let(:subscriber) do
    EdiGem::Subscriber.new(member_id: "MOCK00000001", first_name: "Testfirst",
                           last_name: "Testlast", date_of_birth: "19800101")
  end

  def eligibility_inquiry
    EdiGem::Inquiry::Eligibility.new(payer_code: "FLMCD",
                                     subscriber: subscriber, provider: provider)
  end

  def discovery_inquiry
    EdiGem::Inquiry::Discovery.new(subscriber: subscriber, provider: provider,
                                   as_of: "20260901")
  end

  # A check is billed whether or not the payer can act on it, so an inquiry that cannot match
  # is refused here rather than sent and charged for.
  describe "an inquiry carrying no combination the source matches on" do
    let(:unsearchable) { EdiGem::Subscriber.new(first_name: "Testfirst") }

    def unsearchable_inquiry
      EdiGem::Inquiry::Eligibility.new(payer_code: "FLMCD",
                                       subscriber: unsearchable, provider: provider)
    end

    it "refuses an eligibility check before spending it" do
      source, = stedi_answering(canned("stedi_271_active_coverage"))

      expect { source.eligibility(unsearchable_inquiry) }
        .to raise_error(EdiGem::IdentifiersNotAccepted)
    end

    it "sends nothing when it refuses" do
      source, transport = stedi_answering(canned("stedi_271_active_coverage"))
      begin
        source.eligibility(unsearchable_inquiry)
      rescue EdiGem::IdentifiersNotAccepted
        nil
      end

      expect(transport.paths).to be_empty
    end

    it "names the identifiers it has and the combinations that would work" do
      source, = stedi_answering(canned("stedi_271_active_coverage"))

      expect { source.eligibility(unsearchable_inquiry) }
        .to raise_error(/carries first_name; stedi matches on member_id \+ last_name/)
    end

    it "names no identifier VALUE, because the message reaches logs" do
      source, = stedi_answering(canned("stedi_271_active_coverage"))

      expect { source.eligibility(unsearchable_inquiry) }
        .to raise_error(EdiGem::IdentifiersNotAccepted) do |error|
          expect(error.message).to_not include("Testfirst")
        end
    end

    it "refuses a discovery on the same rule" do
      source, = stedi_answering(canned("stedi_discovery_complete"))

      inquiry = EdiGem::Inquiry::Discovery.new(subscriber: unsearchable, provider: provider,
                                               as_of: "20260901")

      expect { source.discovery(inquiry) }.to raise_error(EdiGem::IdentifiersNotAccepted)
    end
  end

  describe "#eligibility, when the payer confirms coverage" do
    subject(:response) do
      source, = stedi_answering(canned("stedi_271_active_coverage"))
      source.eligibility(eligibility_inquiry)
    end

    it "comes back complete" do
      expect(response.state).to eq(:complete)
    end

    it "reads the one active benefit out of the several the payer listed" do
      expect(response.active_benefits.map(&:plan_name)).to eq(["MEDICAID MANAGED CARE"])
    end

    # The payer's own id for this person, which is what a later check is made with. On every
    # benefit line rather than on one of them: a caller reading a line has to be able to say who
    # it is about without holding the rest of the answer.
    it "reads the member id the payer returned onto every benefit it sent" do
      expect(response.benefits.map(&:member_id)).to eq(%w[MOCK00000001 MOCK00000001])
    end

    it "names the payer that answered on every benefit it sent" do
      expect(response.benefits.map(&:payer_name)).to eq(["MEDICAID FLORIDA", "MEDICAID FLORIDA"])
    end

    it "carries the trace id a dispute about this exchange would be chased with" do
      expect(response.trace_id).to eq("01MOCKACTIVE0000000000000")
    end

    it "says which mode the vendor served it in" do
      expect(response.application_mode).to eq("test")
    end

    it "keeps the body exactly as it arrived" do
      expect(JSON.parse(response.payload.body)["controlNumber"]).to eq("000000001")
    end
  end

  describe "#eligibility, when the payer is down" do
    subject(:response) do
      source, = stedi_answering(canned("stedi_271_payer_down"))
      source.eligibility(eligibility_inquiry)
    end

    it "is payer_silent rather than a refusal of the member" do
      expect(response.state).to eq(:payer_silent)
    end

    # Stedi: a 42 whose follow-up is C, N or S is a problem with the request, not a payer that is down.
    it "says the payer refused the request as sent, not that it is down" do
      expect([response.resubmission_refused?, response.payer_unavailable?]).to eq([true, false])
    end

    # This 42 says "Resubmission Not Allowed" (N): Stedi says not to ask it again, the request has
    # a problem for Stedi support. Asking again here would have taken a second canned answer.
    it "is asked once, since its follow-up is one Stedi says not to ask again after" do
      expect([response.ask_again?, response.exchanges.size]).to eq([false, 1])
    end

    it "counts the refusal once, though the vendor lists it twice" do
      expect(response.rejections.size).to eq(1)
    end
  end

  # Stedi answers a payer ID it can't connect to with a 400 that holds an AAA 79, "There is a
  # problem connecting with this payer": the same finding a 79 in a 200 is.
  describe "#eligibility, when Stedi can't connect to the payer and answers with a 400" do
    subject(:response) do
      source, = stedi_answering(canned("stedi_271_payer_aaa", status: 400))
      source.eligibility(eligibility_inquiry)
    end

    it "reads the 79 as a 200's is read: the payer unreached, and not asked again" do
      expect([response.state, response.payer_unavailable?, response.ask_again?]).to eq([:payer_silent, true, false])
    end

    it "keeps the status the answer came with" do
      expect(response.exchanges.map(&:status)).to eq([400])
    end
  end

  describe "#eligibility, when Stedi answers with a 400 that holds no AAA" do
    let(:archive) { RecordingArchive.new }

    def refused(body)
      source, = stedi_answering(answering(body, status: 400), archive: archive)
      source.eligibility(eligibility_inquiry, archive: { name: "84213" })
    end

    it "raises the Fault the status means, as before" do
      expect { refused(JSON.generate("code" => "BAD_REQUEST")) }
        .to raise_error(an_object_having_attributes(kind: :malformed_request, status: 400,
                                                    path: "/2024-04-01/change/medicalnetwork/eligibility/v3"))
    end

    it "raises it for a body that is not JSON, and files nothing" do
      expect { refused("<html>gateway</html>") }.to raise_error(EdiGem::Fault)
      expect(archive.kept).to be_empty
    end
  end

  describe "#eligibility, when the archive cannot file the answer" do
    let(:archive) do
      Class.new(RecordingArchive) do
        def keep(*, **) = raise(EdiGem::ArchiveFailed.new("s3://warehouse could not be reached", retryable: true))
      end.new
    end
    let(:response) do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      source.eligibility(eligibility_inquiry, archive: { name: "84213" })
    end

    it "returns the paid answer whole, unstored" do
      expect([response.state, response.archived?, response.stored]).to eq([:complete, false, nil])
    end

    it "carries the failure for the caller to report" do
      expect(response.archive_failure).to have_attributes(class: EdiGem::ArchiveFailed, retryable?: true)
    end
  end

  describe "#eligibility, when the archive files the answer" do
    it "carries no failure" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: RecordingArchive.new)
      response = source.eligibility(eligibility_inquiry, archive: { name: "84213" })

      expect([response.archived?, response.archive_failure]).to eq([true, nil])
    end
  end

  # Stedi's troubleshooting guide: ask a payer that can't answer right now again at once, and keep
  # asking for up to two minutes. A clock the sleeper moves stands in for the time that passes.
  describe "#eligibility, when the payer can't answer right now" do
    let(:clock) do
      Class.new do
        attr_accessor :seconds

        def initialize = @seconds = 0
        def clock_gettime(_kind) = @seconds
      end.new
    end
    let(:slept) { [] }
    let(:sleeper) do
      waits = slept
      timer = clock
      Class.new { define_method(:sleep) { |seconds| (waits << seconds) && (timer.seconds += seconds) } }.new
    end
    let(:pauses) { [1, 5, 10] }

    # The fixture's 42 with another AAA03 and follow-up, in both of the lists Stedi sends it in.
    def down(code: "42", followup: "Please Resubmit Original Transaction")
      body = JSON.parse(File.read(File.join(CannedSource::FIXTURES, "stedi_271_payer_down.json")))
      [body["payer"]["aaaErrors"].first, body["errors"].first].each do |error|
        error.merge!("code" => code, "followupAction" => followup)
      end
      canned_body(body)
    end

    def asked(*answers)
      source, transport = stedi_answering(*answers, payer_pauses: pauses, sleeper: sleeper, clock: clock)
      [source.eligibility(eligibility_inquiry), transport]
    end

    def keys(response) = response.exchanges.map { |exchange| exchange.request_headers["idempotency-key"] }

    it "asks again after the first pause and returns the payer's answer" do
      response, = asked(down, canned("stedi_271_active_coverage"))

      expect([response.state, slept]).to eq([:complete, [1]])
    end

    it "asks again under a key of its own, the first key with -r1" do
      first, = stedi_answering(canned("stedi_271_active_coverage"))
      first_key = keys(first.eligibility(eligibility_inquiry)).first
      response, = asked(down, canned("stedi_271_active_coverage"))

      expect(keys(response)).to eq(["#{first_key}-r1"])
    end

    it "keeps to the caller's key, with -r1, -r2 for each ask again" do
      source, = stedi_answering(down, down, canned("stedi_271_active_coverage"),
                                payer_pauses: pauses, sleeper: sleeper, clock: clock)

      expect(keys(source.eligibility(eligibility_inquiry, idempotency_key: "today"))).to eq(["today-r2"])
    end

    it "asks again an 80 whose follow-up says Resubmission Not Allowed" do
      response, = asked(down(code: "80", followup: "Resubmission Not Allowed"), canned("stedi_271_active_coverage"))

      expect(response.state).to eq(:complete)
    end

    it "waits each pause once and returns the last can't-answer WHEN the payer stays down" do
      response, transport = asked(down, down, down, down)

      expect([response.state, response.payer_unavailable?, slept, transport.paths.size])
        .to eq([:payer_silent, true, [1, 5, 10], 4])
    end

    # Stedi: "79 alone: don't automatically retry", but retry a 42 that comes with a 79.
    it "asks once WHEN the payer's only refusal is a 79" do
      response, transport = asked(canned("stedi_271_payer_aaa"))

      expect([response.payer_unavailable?, response.ask_again?, transport.paths.size]).to eq([true, false, 1])
    end

    it "asks again WHEN a 42 comes beside a 79" do
      body = JSON.parse(File.read(File.join(CannedSource::FIXTURES, "stedi_271_payer_down.json")))
      seventy_nine = { "field" => "AAA", "code" => "79", "description" => "Invalid Participant Identification",
                       "followupAction" => "Please Correct and Resubmit", "location" => "Loop 2000A" }
      body["payer"]["aaaErrors"].first["followupAction"] = "Please Resubmit Original Transaction"
      body["payer"]["aaaErrors"] << seventy_nine
      response, = asked(canned_body(body), canned("stedi_271_active_coverage"))

      expect([response.state, slept]).to eq([:complete, [1]])
    end

    it "asks once WHEN the caller passes no pauses" do
      source, transport = stedi_answering(down, payer_pauses: [], sleeper: sleeper, clock: clock)

      expect([source.eligibility(eligibility_inquiry).state, transport.paths.size]).to eq([:payer_silent, 1])
    end

    it "starts no ask again that would begin two minutes or more after the first send" do
      slow = Class.new(CannedSource::Transport) do
        attr_writer :timer

        define_method(:perform) do |path:, retry_until: nil|
          @timer.seconds += 50
          super(path: path, retry_until: retry_until)
        end
      end.new([down, down, down, down])
      slow.timer = clock
      source = EdiGem::Source::Stedi.new(api_key: "test_key", transport: slow, archive: nil,
                                         payer_pauses: pauses, sleeper: sleeper, clock: clock)
      source.eligibility(eligibility_inquiry)

      # Sends at 0-50 s and 51-101 s; a third would start at 106 s and is allowed; the next pause
      # would end at 166 s, past 120.
      expect([slow.paths.size, slept]).to eq([3, [1, 5]])
    end

    it "tells the transport the same two-minute end for every send" do
      _, transport = asked(down, canned("stedi_271_active_coverage"))

      expect(transport.retry_untils).to eq([120, 120])
    end
  end

  # A check costs money. Transport re-sends the same request object, so an in-call retry was
  # already safe; the case this covers is the one above the gem -- a job retry, a re-queued
  # batch -- where a fresh random key would be a second charge for a question already asked.
  describe "the Idempotency-Key" do
    def key_from(response)
      response.exchanges.first.request_headers["idempotency-key"]
    end

    it "is the same for the same question asked twice" do
      first, = stedi_answering(canned("stedi_271_active_coverage"))
      again, = stedi_answering(canned("stedi_271_active_coverage"))

      expect(key_from(first.eligibility(eligibility_inquiry)))
        .to eq(key_from(again.eligibility(eligibility_inquiry)))
    end

    it "differs when the member differs" do
      first, = stedi_answering(canned("stedi_271_active_coverage"))
      other, = stedi_answering(canned("stedi_271_active_coverage"))
      others = EdiGem::Inquiry::Eligibility.new(
        payer_code: "FLMCD", provider: provider,
        subscriber: EdiGem::Subscriber.new(member_id: "MOCK00000002", last_name: "Testlast")
      )

      expect(key_from(first.eligibility(eligibility_inquiry)))
        .to_not eq(key_from(other.eligibility(others)))
    end

    it "differs between an eligibility check and a discovery of the same person" do
      check, = stedi_answering(canned("stedi_271_active_coverage"))
      find, = stedi_answering(canned("stedi_discovery_complete"))

      expect(key_from(check.eligibility(eligibility_inquiry)))
        .to_not eq(key_from(find.discovery(discovery_inquiry)))
    end

    it "can be overridden to force a fresh check of a question already asked" do
      source, = stedi_answering(canned("stedi_271_active_coverage"))

      expect(key_from(source.eligibility(eligibility_inquiry, idempotency_key: "forced")))
        .to eq("forced")
    end
  end

  describe "#discovery" do
    it "calls the discovery endpoint and not the eligibility one" do
      source, transport = stedi_answering(canned("stedi_discovery_complete"))
      source.discovery(discovery_inquiry)

      expect(transport.paths).to eq(["/2024-04-01/insurance-discovery/check/v1"])
    end

    it "sends the address asked with, as Stedi names it" do
      address = EdiGem::Address.new(line1: "1 Example St", postal_code: "40000")
      subscriber = EdiGem::Subscriber.new(first_name: "Testfirst", address: address)
      inquiry = EdiGem::Inquiry::Discovery.new(subscriber: subscriber, provider: discovery_inquiry.provider,
                                               as_of: "20260901")

      expect(EdiGem::Source::Stedi.new(api_key: "test_key").discovery_body(inquiry)[:subscriber][:address])
        .to eq(address1: "1 Example St", postalCode: "40000")
    end

    it "reads a found coverage out of the items list" do
      source, = stedi_answering(canned("stedi_discovery_complete"))

      expect(source.discovery(discovery_inquiry).benefits.filter_map(&:payer_name))
        .to eq(["MEDICAID FLORIDA"])
    end

    # `name` on a benefit line is the status's label ("Active Coverage"), not the plan's.
    it "reads the plan's name from planCoverage, as a check does" do
      source, = stedi_answering(canned("stedi_discovery_complete"))

      expect(source.discovery(discovery_inquiry).benefits.filter_map(&:plan_name)).to eq(["EXAMPLE MEDICAID PLAN"])
    end

    # The address the payer has on record, which may differ from the one sent.
    context "WHEN the payer returns the subscriber's address" do
      subject(:found) do
        source, = stedi_answering(canned("stedi_discovery_complete"))
        source.discovery(discovery_inquiry).found_plans.first.person.address
      end

      it "reads the street lines" do
        expect([found.line1, found.line2]).to eq(["123 Example St", "Apt 4"])
      end

      it "reads the city, state and postal code" do
        expect([found.city, found.state, found.postal_code]).to eq(%w[Testville ZZ 00000])
      end

      it "never prints the address when inspected" do
        expect(found.inspect).to_not include("Example St", "Testville")
      end
    end

    # Each item is one coverage: its own payer, benefit lines and people.
    describe "the plans found" do
      subject(:plan) do
        source, = stedi_answering(canned("stedi_discovery_complete"))
        source.discovery(discovery_inquiry).found_plans.tap { |plans| expect(plans.size).to eq(1) }.first
      end

      it "reads the plan's payer and member id" do
        expect([plan.payer_code, plan.member_id, plan[:payer_name]]).to eq([plan.benefits.first.payer_code,
                                                                            plan.benefits.first.member_id,
                                                                            "MEDICAID FLORIDA"])
      end

      it "keeps the plan's benefit lines" do
        expect(plan.benefits).to all(be_a(EdiGem::Benefit))
      end

      it "names the policyholder as the person matched when there is no dependent" do
        expect([plan.person.role, plan.dependent_people]).to eq([:subscriber, []])
      end

      it "puts no discovery person on the response itself" do
        source, = stedi_answering(canned("stedi_discovery_complete"))

        expect(source.discovery(discovery_inquiry).people).to eq([])
      end
    end

    it "keeps two found plans apart, each with its own people" do
      two = JSON.parse(canned("stedi_discovery_dependent").body)
      other = JSON.parse(JSON.generate(two["items"].first))
      other["payer"]["payorIdentification"] = "00002"
      other.delete("dependent")
      two["items"] << other
      source, = stedi_answering(canned_body(two))
      plans = source.discovery(discovery_inquiry).found_plans

      expect(plans.map { |plan| [plan.payer_code, plan.people.map(&:role), plan.person.relationship_code] })
        .to eq([["00001", %i[subscriber dependent], "19"], ["00002", [:subscriber], "18"]])
    end

    # The old reading took each field from the dependent, else the policyholder, one at a time.
    it "never fills the person matched from the policyholder" do
      body = JSON.parse(canned("stedi_discovery_dependent").body)
      body["items"].first["dependent"].delete("address")
      body["items"].first["subscriber"]["address"] = { "city" => "Elsewhere" }
      source, = stedi_answering(canned_body(body))

      expect(source.discovery(discovery_inquiry).found_plans.first.person.address).to be_nil
    end

    # Discovery matches on demographics and Stedi documents false positives, so a caller has to
    # be able to check the match back against what was sent.
    it "carries the confidence the vendor put on the match" do
      source, = stedi_answering(canned("stedi_discovery_complete"))

      expect(source.discovery(discovery_inquiry).benefits.filter_map { |c| c[:confidence] })
        .to eq(["HIGH"])
    end

    it "is pending when the vendor says PENDING, and hands back the handle to resolve" do
      source, = stedi_answering(canned("stedi_discovery_pending"))
      response = source.discovery(discovery_inquiry)

      expect([response.state, response.handle])
        .to eq([:pending, "00000000-0000-4000-8000-0000000000d2"])
    end

    # The distinction an empty result cannot make on its own, and the reason the vendor's own
    # status is read instead of inferred.
    it "is a finished answer of no coverage when COMPLETE comes back empty" do
      source, = stedi_answering(canned("stedi_discovery_no_coverage"))

      expect(source.discovery(discovery_inquiry).state).to eq(:no_coverage)
    end

    # Stedi's own description of the field: "This is always `production`." It follows the
    # transaction, not the key, so a discovery made on a test key reports production too.
    it "reports production whatever key was used, because discovery always does" do
      source, = stedi_answering(canned("stedi_discovery_complete"))

      expect(source.discovery(discovery_inquiry).application_mode).to eq("production")
    end

    # So this predicate answers false on every discovery ever made, and a caller that reads it
    # as "did this reach a real payer" gets a yes on a call a test key made.
    it "is not test_mode, which is why test_mode? cannot gate a discovery" do
      source, = stedi_answering(canned("stedi_discovery_complete"))

      expect(source.discovery(discovery_inquiry)).to_not be_test_mode
    end
    # Stedi's discovery answer names the lane only in `location`.
    it "is not identified when the subscriber was not found, not a refused request" do
      source, = stedi_answering(canned("stedi_discovery_not_found"))
      response = source.discovery(discovery_inquiry)

      expect([response.state, response.rejections.map(&:level)]).to eq([:not_identified, [:subscriber]])
    end

    it "reads the matched person from the dependent when the patient is one" do
      source, = stedi_answering(canned("stedi_discovery_dependent"))
      plan = source.discovery(discovery_inquiry).found_plans.first

      expect([plan.person.first_name, plan.person.date_of_birth, plan.person.address.city, plan.member_id])
        .to eq(%w[Testfirst 20100101 Example MOCK00001])
    end

    it "raises a vendor_error, not a pending answer, when the vendor says ERROR" do
      source, = stedi_answering(canned("stedi_discovery_error"))

      expect { source.discovery(discovery_inquiry) }
        .to raise_error(EdiGem::Fault) { |fault| expect([fault.kind, fault.retryable?]).to eq([:vendor_error, false]) }
    end
  end

  describe "#resolve" do
    it "reads the result off the discovery handle" do
      source, transport = stedi_answering(canned("stedi_discovery_complete"))
      response = source.resolve("00000000-0000-4000-8000-0000000000d1")

      expect(response.state).to eq(:complete)
      expect(transport.paths)
        .to eq(["/2024-04-01/insurance-discovery/check/v1/00000000-0000-4000-8000-0000000000d1"])
    end
  end

  describe "#archived_discovery" do
    around do |example|
      Dir.mktmpdir("edi-archive") { |dir| @root = dir and example.run }
    end

    let(:archive) { EdiGem::Archive::Local.new(template: "#{@root}/$FEATURE/$DIRECTION") }

    it "reads a kept answer again, the address the payer holds included, and sends nothing more" do
      source, transport = stedi_answering(canned("stedi_discovery_complete"), archive: archive)
      kept = source.discovery(discovery_inquiry, archive: { name: "discovery-1" })

      read = source.archived_discovery(kept.stored.response_uri)

      expect([read.state, read.found_plans.first.person.address.postal_code]).to eq([:complete, "00000"])
      expect(transport.paths.size).to eq(1)
    end

    it "refuses when no archive is configured" do
      source, = stedi_answering

      expect { source.archived_discovery("file:///kept.json") }.to raise_error(EdiGem::ArchiveNotConfigured)
    end

    it "is read by the common name too, its medical plans with the address the payer holds" do
      source, = stedi_answering(canned("stedi_discovery_complete"), archive: archive)
      kept = source.discovery(discovery_inquiry, archive: { name: "discovery-1" })

      plans = source.archived(kept.stored.response_uri, kind: :discovery).medical_plans

      expect(plans.map { |plan| [plan.member_id, plan.person.address.to_h] })
        .to eq([["MOCK00000002", { line1: "123 Example St", line2: "Apt 4", city: "Testville", state: "ZZ",
                                   postal_code: "00000" }]])
    end

    it "raises ArchiveFailed when the kept answer is missing" do
      source, = stedi_answering(archive: archive)

      expect { source.archived("file://#{@root}/missing.json", kind: :discovery) }.to raise_error(EdiGem::ArchiveFailed)
    end
  end

  # A check's kept 271 read again, as a discovery's is: the answer already paid for.
  describe "#archived_eligibility" do
    around do |example|
      Dir.mktmpdir("edi-archive") { |dir| @root = dir and example.run }
    end

    let(:archive) { EdiGem::Archive::Local.new(template: "#{@root}/$FEATURE/$DIRECTION") }

    def kept_check(source) = source.eligibility(eligibility_inquiry, archive: { name: "check-1" })

    it "reads a kept answer again as it was read the day it came, and sends nothing more" do
      source, transport = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      kept = kept_check(source)

      read = source.archived_eligibility(kept.stored.response_uri)

      expect(read.benefits.map(&:status)).to eq(kept.benefits.map(&:status))
      expect(transport.paths.size).to eq(1)
    end

    it "reads a payer's refusals again as they were, with our standing" do
      source, = stedi_answering(canned("stedi_271_payer_aaa"), archive: archive)
      kept = kept_check(source)

      read = source.archived_eligibility(kept.stored.response_uri)

      expect([read.rejections.map(&:code), read.provider_standing])
        .to eq([kept.rejections.map(&:code), kept.provider_standing])
    end

    it "keeps nothing again" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      kept = kept_check(source)

      expect { source.archived_eligibility(kept.stored.response_uri) }
        .to_not(change { Dir.glob("#{@root}/**/*").size })
    end

    it "reads a night's kept batch answer again, as the night read it" do
      source, = stedi_answering(canned("stedi_batch_results_page"), archive: archive)
      kept = source.batch_results("01JB7Q2F3K8N4X5Y6Z7A8B9C0D", archive: { name: "batch-check-1" }).items.first.response

      read = source.archived(kept.stored.response_uri, kind: :eligibility)

      expect(read.benefits.map(&:status)).to eq(kept.benefits.map(&:status))
    end

    it "refuses when no archive is configured" do
      source, = stedi_answering

      expect { source.archived_eligibility("file:///kept.json") }.to raise_error(EdiGem::ArchiveNotConfigured)
    end

    it "raises ArchiveFailed when the kept answer is missing" do
      source, = stedi_answering(archive: archive)

      expect { source.archived_eligibility("file://#{@root}/missing.json") }.to raise_error(EdiGem::ArchiveFailed)
    end

    it "is read by the common name too, as the eligibility kind" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      kept = kept_check(source)

      read = source.archived(kept.stored.response_uri, kind: :eligibility)

      expect(read.benefits.map(&:status)).to eq(kept.benefits.map(&:status))
    end

    it "is never read by the common name without its kind" do
      source, = stedi_answering(archive: archive)

      expect { source.archived("file://#{@root}/kept.json") }.to raise_error(ArgumentError, /kind/)
    end

    it "refuses a kind it has no reader for" do
      source, = stedi_answering(archive: archive)

      expect { source.archived("file://#{@root}/kept.json", kind: :batch) }
        .to raise_error(ArgumentError, /no archived reader/)
    end
  end

  # A discovery poll reads the kept answer back, and asks again only when another read may help:
  # `retryable?` on the ArchiveFailed says which, the same from either archive.
  describe "reading a kept discovery back when the archive fails" do
    around do |example|
      Dir.mktmpdir("edi-archive") { |dir| @root = dir and example.run }
    end

    let(:local) { EdiGem::Archive::Local.new(template: "#{@root}/$FEATURE/$DIRECTION") }
    let(:client) { instance_double(Net::HTTP) }
    let(:s3) do
      EdiGem::Archive::S3.new(template: "s3://warehouse/edi/$FEATURE/$DIRECTION", region: "us-east-1",
                              access_key_id: "AKIA", secret_access_key: "secret", client: client)
    end
    let(:s3_uri) { "s3://warehouse/edi/discovery/response/discovery-1_20260901T000000000Z.json" }

    def failure(archive, uri, read, **kind)
      source, = stedi_answering(archive: archive)
      source.public_send(read, uri, **kind)
    rescue EdiGem::ArchiveFailed => error
      error
    end

    { archived: { kind: :discovery }, archived_discovery: {} }.each do |read, kind|
      describe "##{read}" do
        it "is not retryable WHEN the local file is missing" do
          expect(failure(local, "file://#{@root}/missing.json", read, **kind)).to_not be_retryable
        end

        it "is not retryable WHEN S3 has no such object" do
          allow(client).to receive(:request).and_return(Net::HTTPNotFound.new("1.1", "404", "NoSuchKey"))

          expect(failure(s3, s3_uri, read, **kind)).to_not be_retryable
        end

        it "is retryable WHEN S3 answers that it is failing" do
          allow(client).to receive(:request).and_return(Net::HTTPServiceUnavailable.new("1.1", "503", "Slow Down"))

          expect(failure(s3, s3_uri, read, **kind)).to be_retryable
        end

        it "is retryable WHEN S3 cannot be reached" do
          allow(client).to receive(:request).and_raise(Net::OpenTimeout)

          expect(failure(s3, s3_uri, read, **kind)).to be_retryable
        end
      end
    end
  end

  # Answered with success, so already charged for, and a caller rescuing this gem has to be able to
  # record it rather than ask again.
  describe "an answer whose body is not JSON" do
    it "raises the gem's own error on a check" do
      source, = stedi_answering(answering("<html>gateway</html>"))

      expect { source.eligibility(eligibility_inquiry) }.to raise_error(EdiGem::UnreadableBody)
    end

    it "raises the gem's own error on a discovery read back" do
      source, = stedi_answering(answering("<html>gateway</html>"))

      expect { source.resolve("00000000-0000-4000-8000-0000000000d1") }.to raise_error(EdiGem::UnreadableBody)
    end
  end

  # The source hands back objects rather than bodies, which is the point of it -- a caller reads
  # benefit.status and never parses a 271. The cost is that the raw bytes exist here and nowhere
  # else, so keeping them is this object's job and not the caller's.
  describe "archiving the raw bodies" do
    let(:archive) { RecordingArchive.new }
    let(:filing) { { name: "84213" } }

    it "keeps nothing unless the send asks for it, because most checks do not need it" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)

      expect(source.eligibility(eligibility_inquiry)).to_not be_archived
      expect(archive.kept).to be_empty
    end

    # The vendor and the feature go to the archive as FACTS rather than as a path. Where they
    # land, and whether they appear in the path at all, is the template's business and the
    # caller wrote it.
    it "reports an eligibility check as this vendor and that feature" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      response = source.eligibility(eligibility_inquiry, archive: filing)

      expect(response).to be_archived
      expect(archive.kept.first.clearinghouse).to eq(:stedi)
      expect(archive.kept.first.feature).to eq(:eligibility_check)
    end

    # The gem never derives a file name from the subscriber.
    it "files under the name the caller gave, which is the only place it can come from" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      source.eligibility(eligibility_inquiry, archive: filing)

      expect(archive.kept.first.name).to eq("84213")
    end

    it "passes on whatever else the caller wants the template to key a folder on" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      source.eligibility(eligibility_inquiry, archive: filing.merge(run_id: 7))

      expect(archive.kept.first.supplied).to eq({ run_id: 7 })
    end

    it "hands back where both objects went, which is the only index the caller will have" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      stored = source.eligibility(eligibility_inquiry, archive: filing).stored

      expect(stored.request_uri).to include("/request/")
      expect(stored.response_uri).to include("/response/")
    end

    it "reports a discovery as its own feature, so the two do not share a folder" do
      source, = stedi_answering(canned("stedi_discovery_complete"), archive: archive)
      source.discovery(discovery_inquiry, archive: filing)

      expect(archive.kept.first.feature).to eq(:discovery)
    end

    # The answer arrives on a later GET, and it is the same discovery. Filing it as one keeps a
    # question and the answer it eventually got in the same place.
    it "files the result that arrives on the later GET as the same feature" do
      source, = stedi_answering(canned("stedi_discovery_complete"), archive: archive)
      source.resolve("00000000-0000-4000-8000-0000000000d1", archive: filing)

      expect(archive.kept.map(&:feature)).to eq([:discovery])
    end

    it "files the answer to a discovery the vendor gave up on before raising" do
      source, = stedi_answering(canned("stedi_discovery_error"), archive: archive)

      expect { source.resolve("00000000-0000-4000-8000-0000000000d3", archive: filing) }.to raise_error(EdiGem::Fault)
      expect(archive.kept.map(&:feature)).to eq([:discovery])
    end

    it "keeps what crossed the wire, not our reading of it" do
      source, = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)
      source.eligibility(eligibility_inquiry, archive: filing)

      expect(archive.kept.first.exchange.response_body)
        .to eq(canned("stedi_271_active_coverage").body)
    end

    # The one outcome this exists to prevent: the check is charged for, the answer comes back,
    # and the body it was supposed to keep is gone. So both are checked before anything is sent
    # rather than discovered afterwards.
    describe "before it spends a call it could not file the answer to" do
      it "refuses an eligibility check when nothing is configured to keep it" do
        source, transport = stedi_answering(canned("stedi_271_active_coverage"))

        expect { source.eligibility(eligibility_inquiry, archive: filing) }
          .to raise_error(EdiGem::ArchiveNotConfigured, /EDI_ARCHIVE_TEMPLATE/)
        expect(transport.paths).to be_empty
      end

      it "refuses a discovery when nothing is configured to keep it" do
        source, transport = stedi_answering(canned("stedi_discovery_complete"))

        expect { source.discovery(discovery_inquiry, archive: filing) }
          .to raise_error(EdiGem::ArchiveNotConfigured)
        expect(transport.paths).to be_empty
      end

      it "refuses to resolve a handle it could not keep the answer to" do
        source, transport = stedi_answering(canned("stedi_discovery_complete"))

        expect { source.resolve("00000000-0000-4000-8000-0000000000d1", archive: filing) }
          .to raise_error(EdiGem::ArchiveNotConfigured)
        expect(transport.paths).to be_empty
      end

      # Without a name every body would be written to the same file.
      it "refuses a send that asked to be archived under no name at all" do
        source, transport = stedi_answering(canned("stedi_271_active_coverage"), archive: archive)

        expect { source.eligibility(eligibility_inquiry, archive: { run_id: 7 }) }
          .to raise_error(ArgumentError, /needs a name:/)
        expect(transport.paths).to be_empty
      end
    end
  end
end
