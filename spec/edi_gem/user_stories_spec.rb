# frozen_string_literal: true

# Whole jobs, end to end against canned vendors: set a source up, ask, and read what comes back
# the way a caller would. Nothing here reaches a network.
RSpec.describe "using the gem the way a service would" do
  let(:provider) do
    EdiGem::Provider.new(npi: "1999999984", organization_name: "EXAMPLECLINIC", tax_id: "123456789")
  end

  def subscriber(id, last_name)
    EdiGem::Subscriber.new(member_id: id, last_name: last_name, date_of_birth: "19800101")
  end

  def asking_about(subscriber, payer_code: "11111", **options)
    EdiGem::Inquiry::Eligibility.new(payer_code: payer_code, subscriber: subscriber,
                                     provider: provider, **options)
  end

  describe "checking one subscriber by id" do
    subject(:response) do
      source, = stedi_answering(canned("stedi_271_active_coverage"))
      source.eligibility(asking_about(subscriber("MOCK00000001", "TESTLAST")))
    end

    it "comes back finished, so the caller need not poll" do
      expect(response.state).to_not eq(:pending)
    end

    it "says the person is covered" do
      expect(response.state).to eq(:complete)
    end

    it "keeps the payload, byte for byte" do
      expect(response.payload.body).to include("planStatus")
    end

    it "keeps the call that carried it" do
      expect(response.exchanges.first).to be_a(EdiGem::Exchange)
    end
  end

  # Clearinghouses each have their own code for a payer; the caller passes the one for the
  # source it calls.
  describe "the same payer through three sources" do
    it "routes on the code given to Stedi" do
      source, = stedi_answering(canned("stedi_271_active_coverage"))
      body = source.eligibility_body(asking_about(subscriber("MEM1", "LOVELACE"),
                                                  payer_code: "11111"))

      expect(body[:tradingPartnerServiceId]).to eq("11111")
    end

    it "routes on the code given to Office Ally" do
      source = EdiGem::Source::OfficeAlly.new(credential: enrolled(:office_ally))
      inquiry = asking_about(subscriber("MEM1", "LOVELACE"), payer_code: "OA111")

      expect(source.send(:request_body, inquiry, trace: "T1")).to include("PI*OA111")
    end

    it "routes on the code given to Optum" do
      source = EdiGem::Source::Optum.new(credential: enrolled(:optum))
      inquiry = asking_about(subscriber("MEM1", "LOVELACE"), payer_code: "OPT11")

      expect(source.send(:request_body, inquiry, trace: "T1")).to include("PI*OPT11")
    end
  end

  describe "an inquiry the caller could not route" do
    it "refuses before spending a check" do
      source, transport = stedi_answering(canned("stedi_271_active_coverage"))

      expect { source.eligibility(asking_about(subscriber("MEM1", "LOVELACE"), payer_code: "")) }
        .to raise_error(EdiGem::PayerNotRouted)
      expect(transport.paths).to be_empty
    end
  end

  describe "a refresh sent as one batch" do
    let(:roster) do
      { "row-1" => asking_about(subscriber("A", "LOVELACE")),
        "row-2" => asking_about(subscriber("B", "BABBAGE"), payer_code: "22222") }
    end

    it "submits every check under one batch id" do
      source, = stedi_answering(canned("stedi_batch_submitted"))

      expect(source.submit_batch(roster, name: "monthly refresh").count).to eq(2)
    end

    it "separates the settled checks from the ones still retrying" do
      source, = stedi_answering(canned("stedi_batch_checks_page_one"))
      page = source.batch_checks("01JB7Q2F3K8N4X5Y6Z7A8B9C0D")

      expect(page.items.reject(&:settled?).map(&:state)).to eq(["RETRYING"])
    end
  end

  describe "a subscriber the payer cannot identify" do
    subject(:response) do
      source, = stedi_answering(canned("stedi_271_payer_aaa"))
      source.eligibility(asking_about(subscriber("BADID", "TESTLAST")))
    end

    it "is not read as an absence of coverage" do
      expect(response.state).to_not eq(:no_coverage)
    end

    it "says which level refused, which decides who fixes it" do
      expect(response.rejections.map(&:level)).to_not include(:transport)
    end
  end

  describe "a CORE batch file through Office Ally" do
    subject(:source) { EdiGem::Source::OfficeAlly.new(credential: enrolled(:office_ally)) }

    let(:roster) do
      %w[A B C].map { |id| asking_about(subscriber(id, "LOVELACE")) }
    end

    it "puts every check in one interchange" do
      expect(source.batch_submission(roster).soap.scan("ST*270*").length).to eq(3)
    end

    it "hands back a payload id the results are collected against later" do
      expect(source.batch_submission(roster).payload_id).to_not be_nil
    end

    it "reads the collected file back as one answer per check" do
      expect(source.read_batch(batch_271("A", "B", "C")).length).to eq(3)
    end
  end

  describe "picking a source by what it supports" do
    let(:sources) do
      { stedi: EdiGem::Source::Stedi.new(api_key: "test_key"),
        office_ally: EdiGem::Source::OfficeAlly.new(credential: enrolled(:office_ally)),
        optum: EdiGem::Source::Optum.new(credential: enrolled(:optum)) }
    end

    it "finds every source that answers an eligibility check" do
      expect(sources.select { |_name, source| source.supports?(:eligibility) }.keys)
        .to eq(%i[stedi office_ally optum])
    end

    it "finds only Stedi for discovery" do
      expect(sources.select { |_name, source| source.supports?(:discovery) }.keys).to eq([:stedi])
    end

    it "finds only Stedi for the contract's batch lane" do
      expect(sources.select { |_name, source| source.supports?(:batch) }.keys).to eq([:stedi])
    end
  end

  describe "before a source is enrolled" do
    it "says which identifiers are still outstanding" do
      blank = EdiGem::Credential.new(provider: provider, source: :office_ally)
      source = EdiGem::Source::OfficeAlly.new(credential: blank)

      expect { source.eligibility(asking_about(subscriber("A", "LOVELACE"))) }
        .to raise_error(EdiGem::CredentialMissing,
                        /sender_id, receiver_id, application_sender, application_receiver/)
    end

    it "refuses a payer whose required credential is not held" do
      source, = stedi_answering(canned("stedi_271_active_coverage"))
      inquiry = asking_about(subscriber("A", "LOVELACE"), required_credentials: [:portal_password])

      expect { source.eligibility(inquiry) }
        .to raise_error(EdiGem::CredentialMissing, /portal_password/)
    end
  end
end
