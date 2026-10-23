# frozen_string_literal: true

require "tmpdir"

RSpec.describe EdiGem::Archive::Local do
  subject(:archive) do
    described_class.new(template: "#{root}/raw/$CLEARINGHOUSE/$YYYYMM/$FEATURE/$DIRECTION")
  end

  around do |example|
    Dir.mktmpdir("edi-archive") { |dir| @root = dir and example.run }
  end

  attr_reader :root

  let(:exchange) do
    EdiGem::Exchange.new(
      method: :post, url: "https://healthcare.us.stedi.com/2024-04-01/change/medicalnetwork",
      request_headers: { "Authorization" => "sk_live_x" },
      request_body: '{"portalPassword":"1234","subscriber":{"memberId":"MEM123"}}',
      status: 200, response_body: '{"benefitsInformation":[]}',
      started_at: Time.utc(2026, 3, 2, 4, 0, 0)
    )
  end

  let(:stored) do
    archive.keep(exchange, clearinghouse: :stedi, feature: :eligibility_check, name: "84213")
  end

  def path(uri) = uri.delete_prefix("file://")

  describe "the bytes it writes" do
    # Rails sets default_internal to UTF-8; a vendor body is binary until something parses it.
    it "writes a body with a byte outside UTF-8 as it arrived, whatever the default encodings" do
      before = Encoding.default_internal
      Encoding.default_internal = Encoding::UTF_8
      body = "{\"name\":\"caf\xE9\"}".b
      binary = EdiGem::Exchange.new(method: :post, url: "https://example.test", status: 200,
                                    request_body: "{}", response_body: body, started_at: Time.utc(2026, 3, 2))
      written = archive.keep(binary, clearinghouse: :stedi, feature: :eligibility_check, name: "84213")

      expect(File.binread(path(written.response_uri))).to eq(body)
    ensure
      Encoding.default_internal = before
    end
  end

  describe "where the two objects land" do
    # The request and the response have different shapes, so they get separate folders.
    it "files the question and the answer in folders of their own" do
      expect(path(stored.request_uri))
        .to eq("#{root}/raw/stedi/202603/eligibility_check/request/84213_20260302T040000000Z.json")
      expect(path(stored.response_uri))
        .to eq("#{root}/raw/stedi/202603/eligibility_check/response/84213_20260302T040000000Z.json")
    end

    # The name comes from the caller, never from the subscriber.
    it "names each file for the name the caller gave and the instant it was asked" do
      expect(File.basename(path(stored.request_uri))).to eq("84213_20260302T040000000Z.json")
    end

    it "reports what it wrote, which is the only index the caller will have" do
      expect(stored.bytes)
        .to eq(File.size(path(stored.request_uri)) + File.size(path(stored.response_uri)))
    end

    it "writes the directories the template names rather than failing on a bucket-shaped path" do
      stored

      expect(Dir).to exist("#{root}/raw/stedi/202603/eligibility_check/response")
    end

    it "fills a placeholder the gem does not supply from what the caller handed over" do
      keyed = described_class.new(template: "#{root}/$RUN_ID/$DIRECTION")
      kept = keyed.keep(exchange, clearinghouse: :stedi, feature: :discovery,
                                  name: "84213", values: { run_id: 7 })

      expect(path(kept.request_uri)).to start_with("#{root}/7/request/")
    end
  end

  describe "one object per attempt" do
    it "keeps the same question asked twice, twice" do
      later = EdiGem::Exchange.new(method: :post, url: exchange.url, status: 200,
                                   request_body: exchange.request_body,
                                   response_body: exchange.response_body,
                                   started_at: Time.utc(2026, 3, 2, 4, 0, 1))
      second = archive.keep(later, clearinghouse: :stedi, feature: :eligibility_check,
                                   name: "84213")

      expect(second.request_uri).to_not eq(stored.request_uri)
    end

    # The stamp goes to the millisecond, so a quick retry is a second object.
    it "separates two attempts inside the same second" do
      retried = EdiGem::Exchange.new(method: :post, url: exchange.url, status: 200,
                                     request_body: exchange.request_body,
                                     response_body: exchange.response_body,
                                     started_at: Time.utc(2026, 3, 2, 4, 0, 0.25))

      expect(archive.keep(retried, clearinghouse: :stedi, feature: :eligibility_check,
                                   name: "84213").request_uri)
        .to end_with("84213_20260302T040000250Z.json")
    end

    # Dated from the exchange rather than from now, so a body written on a retry hours later
    # still sits in the month the payer was actually asked in.
    it "cannot file an exchange that never started, rather than filing it under today" do
      unstarted = EdiGem::Exchange.new(method: :post, url: "https://x.test", status: 0)

      expect { archive.keep(unstarted, clearinghouse: :stedi, feature: :discovery, name: "1") }
        .to raise_error(ArgumentError, /no started_at/)
    end
  end

  describe "the name a body is filed under" do
    def kept_with(name)
      archive.keep(exchange, clearinghouse: :stedi, feature: :discovery, name: name)
    end

    it "is required, because a file has to be called something" do
      expect { kept_with(nil) }.to raise_error(ArgumentError, /a name is required/)
      expect { kept_with("") }.to raise_error(ArgumentError, /a name is required/)
    end

    # It becomes part of a signed S3 key, so a name needing percent-encoding would be encoded
    # once by the URI and again by the signature and refused with a message naming neither.
    it "cannot be spelled with a character S3 could not be asked for" do
      expect { kept_with("member 42") }.to raise_error(ArgumentError, /cannot be written as a/)
    end
  end

  describe "what is in the two files" do
    it "keeps the answer byte for byte, which is what a dispute is settled with" do
      expect(File.read(path(stored.response_uri))).to eq(exchange.response_body)
    end

    it "keeps the PHI, which is the whole point of the record and what the bucket is for" do
      expect(File.read(path(stored.request_uri))).to include("MEM123")
    end

    it "redacts a portal credential the source sent inside the request body" do
      expect(JSON.parse(File.read(path(stored.request_uri)))["portalPassword"])
        .to eq("[redacted]")
    end

    # Rewriting an X12 body would break the envelope it has to be read back with, and no X12
    # source sends a credential in the payload anyway.
    it "leaves a body that is not our own JSON exactly as it crossed the wire" do
      x12 = "ISA*00*          *00*          *ZZ*SUBMITTER~GS*HS*X*Y~"

      expect(kept_request(x12)).to eq(x12)
    end

    it "leaves a JSON body that is not an object alone" do
      expect(kept_request("[1,2]")).to eq("[1,2]")
    end

    def kept_request(body)
      sent = EdiGem::Exchange.new(method: :post, url: "https://x.test", status: 200,
                                  request_body: body, response_body: "{}",
                                  started_at: Time.utc(2026, 3, 2))
      kept = archive.keep(sent, clearinghouse: :optum, feature: :eligibility_check, name: "1")
      File.read(path(kept.request_uri))
    end
  end

  # A call that answered with nothing -- a 204, or one the transport recorded no body for -- is
  # still worth filing. The question we asked is the half an audit needs, and losing it because
  # the answer was empty is how "we never sent that" becomes unanswerable.
  it "files the question even when nothing came back to file beside it" do
    empty = EdiGem::Exchange.new(method: :post, url: "https://x.test", status: 204,
                                 request_body: '{"a":1}', started_at: Time.utc(2026, 3, 2))
    kept = archive.keep(empty, clearinghouse: :stedi, feature: :eligibility_check, name: "84213")

    expect(kept.response_uri).to be_nil
    expect(kept.request_uri).to include("/request/")
    expect(kept.bytes).to eq(7)
  end

  # Resolving a discovery handle is a GET. Its question is the URL, which belongs on the caller's
  # own row rather than in an object pretending to be a body.
  it "writes no request object for a call that carried no body" do
    get = EdiGem::Exchange.new(method: :get, url: "https://x.test/d/1", status: 200,
                               response_body: "{}", started_at: Time.utc(2026, 3, 2))
    kept = archive.keep(get, clearinghouse: :stedi, feature: :discovery, name: "84213")

    expect(kept.request_uri).to be_nil
    expect(kept.response_uri).to include("/response/")
  end

  describe "reading a kept body back" do
    it "answers with the bytes written" do
      expect(archive.fetch(stored.response_uri)).to eq(exchange.response_body)
    end

    it "raises when nothing is kept there" do
      expect { archive.fetch("file://#{root}/missing.json") }.to raise_error(EdiGem::ArchiveFailed)
    end

    it "says a missing file will not appear by asking again" do
      expect { archive.fetch("file://#{root}/missing.json") }
        .to raise_error(EdiGem::ArchiveFailed) { |failed| expect(failed).to_not be_retryable }
    end

    it "says a refused permission will not pass by asking again" do
      allow(File).to receive(:binread).and_raise(Errno::EACCES)

      expect { archive.fetch(stored.response_uri) }
        .to raise_error(EdiGem::ArchiveFailed, /Errno::EACCES/) { |failed| expect(failed).to_not be_retryable }
    end

    [Errno::EAGAIN, Errno::EINTR, Errno::EBUSY, Errno::ETIMEDOUT].each do |kind|
      it "says a read the system interrupted with #{kind} may pass later" do
        allow(File).to receive(:binread).and_raise(kind)

        expect { archive.fetch(stored.response_uri) }
          .to raise_error(EdiGem::ArchiveFailed, /#{kind}/) { |failed| expect(failed).to be_retryable }
      end
    end

    it "refuses a uri that is not a file's, as a failure asking again will not change" do
      expect { archive.fetch("s3://warehouse/x.json") }
        .to raise_error(EdiGem::ArchiveFailed, /is not a local archive's/) { |failed| expect(failed).to_not be_retryable }
    end
  end
end
