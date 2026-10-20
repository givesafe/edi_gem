# frozen_string_literal: true

require "tmpdir"

# Stedi's batch endpoints, end to end against canned responses written from its API reference.
RSpec.describe "batching through Stedi" do
  let(:provider) { EdiGem::Provider.new(npi: "1999999984", organization_name: "Example Clinic") }

  def subscriber(member_id)
    EdiGem::Subscriber.new(member_id: member_id, first_name: "Testfirst",
                           last_name: "Testlast", date_of_birth: "19800101")
  end

  def inquiry(member_id, payer_code: "11111")
    EdiGem::Inquiry::Eligibility.new(payer_code: payer_code,
                                     subscriber: subscriber(member_id), provider: provider)
  end

  # The body sent, read off the exchange the submission keeps.
  def sent_body(result)
    JSON.parse(result.exchange.request_body)
  end

  def sent_items(result)
    sent_body(result)["items"]
  end

  def submitted(source)
    source.submit_batch({ "member-7087" => inquiry("MOCK00000001"),
                          "member-7091" => inquiry("MOCK00000002", payer_code: "22222") },
                        name: "monthly refresh")
  end

  describe "the endpoints it will call" do
    let(:policy) { EdiGem::Policy.for(EdiGem::Source::Stedi::NAME) }

    it "sends a batch to the manager host, not the real-time one" do
      expect(policy.for_operation(:batch_eligibility).base_url)
        .to eq("https://manager.us.stedi.com")
    end

    it "still sends a real-time check to the healthcare host" do
      expect(policy.for_operation(:eligibility).base_url).to eq("https://healthcare.us.stedi.com")
    end

    it "declares the batch endpoint it actually has" do
      expect(EdiGem::Source::Stedi.new(api_key: "test_key").capabilities[:batch]).to be(true)
    end
  end

  describe "#submit_batch" do
    it "hands back the id the answers will arrive under" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(submitted(source).id).to eq("01JB7Q2F3K8N4X5Y6Z7A8B9C0D")
    end

    it "records how many checks went in, which the vendor does not echo" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(submitted(source).count).to eq(2)
    end

    it "keeps the exchange, because a submission is a billing record" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(submitted(source).exchange).to_not be_nil
    end

    # The only way to correlate an answer with its check.
    it "sends each caller's identifier with its check" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(sent_items(submitted(source)).map { |item| item["submitterTransactionIdentifier"] })
        .to eq(%w[member-7087 member-7091])
    end

    it "resolves the payer code per item, because a batch may mix payers" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(sent_items(submitted(source)).map { |item| item["tradingPartnerServiceId"] })
        .to eq(%w[11111 22222])
    end

    it "names the batch when it was given a name" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(sent_body(submitted(source))["name"]).to eq("monthly refresh")
    end

    it "omits maxRetryHours rather than sending a default the vendor already has" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(sent_body(submitted(source))).to_not have_key("maxRetryHours")
    end

    it "sends the retry window when one was asked for" do
      source, = stedi_answering(canned("stedi_batch_submitted"))
      result = source.submit_batch([inquiry("MOCK00000001")], max_retry_hours: 24)

      expect(sent_body(result)["maxRetryHours"]).to eq(24)
    end

    it "derives its idempotency key from the batch, so the same batch sent twice is one batch" do
      first, = stedi_answering(canned("stedi_batch_submitted"))
      again, = stedi_answering(canned("stedi_batch_submitted"))

      expect(submitted(first).exchange.request_headers["idempotency-key"])
        .to eq(submitted(again).exchange.request_headers["idempotency-key"])
    end

    it "sends the idempotency key it was given in place of the derived one" do
      source, = stedi_answering(canned("stedi_batch_submitted"))
      result = source.submit_batch([inquiry("MOCK00000001")], idempotency_key: "forced")

      expect(result.exchange.request_headers["idempotency-key"]).to eq("forced")
    end

    it "keys a bare list by position, which correlates within this run only" do
      source, = stedi_answering(canned("stedi_batch_submitted"))
      result = source.submit_batch([inquiry("MOCK00000001"), inquiry("MOCK00000002")])

      expect(sent_items(result).map { |item| item["submitterTransactionIdentifier"] })
        .to eq(%w[0 1])
    end

    it "refuses the whole batch rather than sending a check that cannot match" do
      source, = stedi_answering(canned("stedi_batch_submitted"))
      unsearchable = EdiGem::Inquiry::Eligibility.new(
        payer_code: "11111", provider: provider,
        subscriber: EdiGem::Subscriber.new(first_name: "Testfirst")
      )

      expect { source.submit_batch([unsearchable]) }
        .to raise_error(EdiGem::IdentifiersNotAccepted)
    end
  end

  describe "#batch_status" do
    subject(:status) do
      source, = stedi_answering(canned("stedi_batch_status_in_progress"))
      source.batch_status("01JB7Q2F3K8N4X5Y6Z7A8B9C0D")
    end

    it "reads the state" do
      expect(status.state).to eq("IN_PROGRESS")
    end

    it "reads the counts that say how far along it is" do
      expect([status.total, status.succeeded, status.failed, status.in_progress])
        .to eq([4, 2, 1, 1])
    end

    it "is not finished while the vendor is still retrying a payer" do
      expect(status).to_not be_finished
    end

    # The batch is over though no payer was asked.
    it "is finished when validation failed, which asks no payer at all" do
      source, = stedi_answering(canned("stedi_batch_status_validation_failed"))

      expect(source.batch_status("01JB7Q2F3K8N4X5Y6Z7A8B9C0E")).to be_finished
    end

    it "asks for the batch by id" do
      source, transport = stedi_answering(canned("stedi_batch_status_in_progress"))
      source.batch_status("01JB7Q2F3K8N4X5Y6Z7A8B9C0D")

      expect(transport.paths.last)
        .to eq("/2024-04-01/eligibility-manager/batch/01JB7Q2F3K8N4X5Y6Z7A8B9C0D")
    end
  end

  describe "#batch_checks" do
    subject(:page) do
      source, = stedi_answering(canned("stedi_batch_checks_page_one"))
      source.batch_checks("01JB7Q2F3K8N4X5Y6Z7A8B9C0D")
    end

    it "reads every check on the page" do
      expect(page.size).to eq(3)
    end

    it "correlates each answer back by the identifier we sent" do
      expect(page.items.map(&:identifier))
        .to eq(%w[member-7087 member-7091 member-7154])
    end

    # Whether the vendor finished asking, and what the payer said.
    it "keeps the processing state apart from the payer's answer" do
      expect(page.items.map { |check| [check.state, check.result] })
        .to eq([%w[COMPLETED ACTIVE], %w[COMPLETED INACTIVE], ["RETRYING", nil]])
    end

    it "reports only the finished checks as settled" do
      expect(page.items.map(&:settled?)).to eq([true, true, false])
    end

    it "reports only an ACTIVE result as active" do
      expect(page.items.map(&:active?)).to eq([true, false, false])
    end

    it "names the payer the vendor asked" do
      expect(page.items.first.payer_code).to eq("11111")
    end

    it "prints no member details when inspected, because a check carries PHI" do
      expect(page.items.first.inspect).to_not include("MOCK00000001")
    end

    # The token, not the item count, says whether more pages follow.
    it "says there is more when the vendor sent a token" do
      expect(page).to be_more
    end

    it "says there is no more when the vendor sent none" do
      source, = stedi_answering(canned("stedi_batch_checks_last_page"))

      expect(source.batch_checks("01JB7Q2F3K8N4X5Y6Z7A8B9C0D")).to_not be_more
    end

    it "asks for the next page with the token the last one gave" do
      source, transport = stedi_answering(canned("stedi_batch_checks_last_page"))
      source.batch_checks("01JB7Q2F3K8N4X5Y6Z7A8B9C0D", page_token: "eyJwYWdlIjoyfQ")

      expect(transport.paths.last).to include("pageToken=eyJwYWdlIjoyfQ")
    end

    it "asks for a page size when one was given" do
      source, transport = stedi_answering(canned("stedi_batch_checks_last_page"))
      source.batch_checks("01JB7Q2F3K8N4X5Y6Z7A8B9C0D", page_size: 1000)

      expect(transport.paths.last).to include("pageSize=1000")
    end

    it "asks for the items under the batch id" do
      expect(page.exchange.url)
        .to end_with("/2024-04-01/eligibility-manager/batch/01JB7Q2F3K8N4X5Y6Z7A8B9C0D/items")
    end

    it "asks the manager host rather than the real-time one" do
      expect(page.exchange.url).to start_with("https://manager.us.stedi.com/")
    end

    # The raw item is how a caller reads a field the gem does not model.
    it "hands back each item as the vendor sent it" do
      expect(page.items.first.raw.dig("additionalInfo", "eligibility", "payerId")).to eq("11111")
    end

    it "has filed nothing, and says so, when it was not asked to" do
      expect(page.items.map(&:stored)).to all(be_nil)
    end
  end

  describe "#batch_checks with archive:" do
    let(:archive) { RecordingArchive.new }
    let(:batch_id) { "01JB7Q2F3K8N4X5Y6Z7A8B9C0D" }

    def read_page(fixture = "stedi_batch_checks_page_one", **filing)
      source, transport = stedi_answering(canned(fixture), archive: archive)
      [source.batch_checks(batch_id, archive: { name: "batch-42" }.merge(filing)), transport]
    end

    it "files each item on its own, under the identifier we sent with it" do
      read_page

      expect(archive.kept.map(&:name))
        .to eq(%w[batch-42_member-7087 batch-42_member-7091 batch-42_member-7154])
    end

    it "files them as this vendor's batch checks" do
      read_page

      expect(archive.kept.map { |kept| [kept.clearinghouse, kept.feature] }.uniq)
        .to eq([%i[stedi batch_check]])
    end

    it "files the item's own answer, not the whole page" do
      page, = read_page
      body = JSON.parse(archive.kept.first.exchange.response_body)

      expect(body).to eq(page.items.first.raw)
    end

    it "files no request, because an item has none" do
      read_page

      expect(archive.kept.map { |kept| kept.exchange.request_body }).to all(be_nil)
    end

    it "dates each object from the call that read the page" do
      page, = read_page

      expect(archive.kept.map { |kept| kept.exchange.started_at }.uniq)
        .to eq([page.exchange.started_at])
    end

    it "puts where each item went on that item, in the order they came" do
      page, = read_page

      expect(page.items.map { |check| check.stored.response_uri }).to eq(
        %w[member-7087 member-7091 member-7154].map do |id|
          "s3://warehouse/batch_check/response/batch-42_#{id}.json"
        end
      )
    end

    it "passes on whatever else the caller wants the template to key a folder on" do
      read_page(run_id: 7)

      expect(archive.kept.map(&:supplied).uniq).to eq([{ run_id: 7 }])
    end

    it "files one object for each item, however many the page holds" do
      page, = read_page("stedi_batch_checks_last_page")

      expect(archive.kept.size).to eq(page.items.size)
    end

    it "refuses before asking when there is nowhere to file", :aggregate_failures do
      source, transport = stedi_answering(canned("stedi_batch_checks_page_one"))

      expect { source.batch_checks(batch_id, archive: { name: "batch-42" }) }
        .to raise_error(EdiGem::ArchiveNotConfigured)
      expect(transport.paths).to be_empty
    end

    it "refuses before asking when it was given no name to file under", :aggregate_failures do
      source, transport = stedi_answering(canned("stedi_batch_checks_page_one"), archive: archive)

      expect { source.batch_checks(batch_id, archive: { name: "" }) }
        .to raise_error(ArgumentError, /name/)
      expect(transport.paths).to be_empty
    end

    it "actually writes one object per item through a real archive" do
      Dir.mktmpdir("edi-archive") do |root|
        local = EdiGem::Archive::Local.new(template: "#{root}/$FEATURE/$DIRECTION")
        source, = stedi_answering(canned("stedi_batch_checks_page_one"), archive: local)
        page = source.batch_checks(batch_id, archive: { name: "batch-42" })
        written = File.read(page.items.last.stored.response_uri.delete_prefix("file://"))

        expect(JSON.parse(written)).to eq(page.items.last.raw)
      end
    end

    context "when an item cannot be filed" do
      def item(identifier)
        eligibility = { "submitterTransactionIdentifier" => identifier }.compact
        { "state" => "COMPLETED", "additionalInfo" => { "eligibility" => eligibility } }
      end

      # A good item first, so a page filed one at a time would leave it behind.
      def page_with(identifier)
        answering(JSON.generate(items: [item("member-7087"), item(identifier)]))
      end

      it "raises for a name the archive cannot write, and files none of the page" do
        source, = stedi_answering(page_with("member-7091"), archive: archive)

        expect { source.batch_checks(batch_id, archive: { name: "not a file name" }) }
          .to raise_error(ArgumentError, /cannot be filed/)
        expect(archive.kept).to be_empty
      end

      [nil, "", "has a space", "../escape"].each do |identifier|
        it "raises for the identifier #{identifier.inspect}, and files none of the page" do
          source, = stedi_answering(page_with(identifier), archive: archive)

          expect { source.batch_checks(batch_id, archive: { name: "batch-42" }) }
            .to raise_error(ArgumentError, /cannot be filed under that name and its identifier/)
          expect(archive.kept).to be_empty
        end
      end
    end
  end
end
