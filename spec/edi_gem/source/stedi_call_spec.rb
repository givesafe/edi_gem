# frozen_string_literal: true

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

    # AAA 42 arrives saying "Resubmission Not Allowed" and Stedi documents it as retry anyway.
    it "reports the refusal as worth another attempt" do
      expect(response.rejections.map(&:retryable?)).to eq([true])
    end

    it "counts the refusal once, though the vendor lists it twice" do
      expect(response.rejections.size).to eq(1)
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
