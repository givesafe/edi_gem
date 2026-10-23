# frozen_string_literal: true

RSpec.describe EdiGem::Archive::S3 do
  subject(:archive) do
    described_class.new(template: "s3://warehouse/raw/$CLEARINGHOUSE/$YYYYMM/$FEATURE/$DIRECTION",
                        region: "us-west-2", access_key_id: "AKIA",
                        secret_access_key: "secret", client: client)
  end

  let(:client) { instance_double(Net::HTTP) }
  let(:response) { Net::HTTPOK.new("1.1", "200", "OK") }
  let(:sent) { [] }

  let(:exchange) do
    EdiGem::Exchange.new(method: :post, url: "https://healthcare.us.stedi.com/x", status: 200,
                         request_body: '{"subscriber":{"memberId":"MEM123"}}',
                         response_body: '{"benefitsInformation":[]}',
                         started_at: Time.utc(2026, 3, 2, 4, 0, 0))
  end

  let(:stored) do
    archive.keep(exchange, clearinghouse: :stedi, feature: :eligibility_check, name: "84213")
  end

  before { allow(client).to receive(:request) { |request| sent << request and response } }

  describe "the bucket, which the template names" do
    # Virtual-hosted addressing is the only style AWS supports for new buckets, and a dotted name
    # does not match the wildcard certificate it serves. The handshake fails rather than the
    # request, so the error names TLS and not the bucket.
    it "cannot be a dotted name, which no longer reaches S3 over TLS at all" do
      expect do
        described_class.new(template: "s3://example.bucket/raw/$DIRECTION", region: "us-east-1",
                            access_key_id: "A", secret_access_key: "s")
      end.to raise_error(ArgumentError, /dot cannot be reached over TLS/)
    end

    it "is addressed virtual-hosted, in its own region" do
      expect(archive.endpoint.to_s).to eq("https://warehouse.s3.us-west-2.amazonaws.com")
      expect(archive.bucket).to eq("warehouse")
    end
  end

  describe "keeping an exchange" do
    it "PUTs one object for the question and one for the answer" do
      stored

      expect(sent.map(&:method)).to eq(%w[PUT PUT])
      expect(sent.map { |request| request.uri.path })
        .to eq(["/#{key_of(stored.request_uri)}", "/#{key_of(stored.response_uri)}"])
    end

    it "answers with s3 uris under the folders the template asked for" do
      expect(stored.request_uri)
        .to eq("s3://warehouse/raw/stedi/202603/eligibility_check/request/" \
               "84213_20260302T040000000Z.json")
      expect(stored.response_uri)
        .to eq("s3://warehouse/raw/stedi/202603/eligibility_check/response/" \
               "84213_20260302T040000000Z.json")
    end

    it "sends the bodies themselves, not a rendering of them" do
      stored

      expect(sent.last.body).to eq(exchange.response_body)
      expect(stored.bytes).to eq(sent.sum { |request| request.body.bytesize })
    end

    it "signs each request, because S3 refuses an unsigned one" do
      stored

      expect(sent.first["authorization"]).to start_with("AWS4-HMAC-SHA256 Credential=AKIA/")
      expect(sent.first["x-amz-content-sha256"]).to eq(Digest::SHA256.hexdigest(sent.first.body))
    end

    # An archive that quietly did not write is worse than no archive: the row says the body is
    # kept and it is not, and nobody finds out until a payer disputes a check.
    it "raises rather than answering with a Stored nobody can read back" do
      allow(client).to receive(:request).and_return(Net::HTTPForbidden.new("1.1", "403", "no"))

      expect { stored }
        .to raise_error(EdiGem::ArchiveFailed, %r{s3://warehouse/raw/stedi/.* answered 403})
    end

    it "raises the same WHEN the bucket cannot be reached at all" do
      allow(client).to receive(:request).and_raise(Net::ReadTimeout)

      expect { stored }
        .to raise_error(EdiGem::ArchiveFailed, %r{s3://warehouse/raw/stedi/.* could not be reached \(Net::ReadTimeout\)})
    end

    it "says a refused write will not pass by asking again" do
      allow(client).to receive(:request).and_return(Net::HTTPForbidden.new("1.1", "403", "no"))

      expect { stored }.to raise_error(EdiGem::ArchiveFailed) { |failed| expect(failed).to_not be_retryable }
    end

    it "says a write S3 answered with Slow Down may pass later" do
      allow(client).to receive(:request).and_return(Net::HTTPServiceUnavailable.new("1.1", "503", "Slow Down"))

      expect { stored }.to raise_error(EdiGem::ArchiveFailed) { |failed| expect(failed).to be_retryable }
    end

    it "says a write that never reached the bucket may pass later" do
      allow(client).to receive(:request).and_raise(Net::ReadTimeout)

      expect { stored }.to raise_error(EdiGem::ArchiveFailed) { |failed| expect(failed).to be_retryable }
    end

    def key_of(uri) = uri.delete_prefix("s3://warehouse/")
  end

  describe "reading a kept body back" do
    let(:uri) { "s3://warehouse/raw/stedi/202603/discovery/response/84213_20260302T040000000Z.json" }
    let(:response) { Net::HTTPOK.new("1.1", "200", "OK").tap { |ok| allow(ok).to receive(:body).and_return("{}") } }

    it "GETs the object, signed, and answers with its body" do
      expect(archive.fetch(uri)).to eq("{}")
      expect(sent.map { |request| [request.method, request.uri.path] })
        .to eq([["GET", "/raw/stedi/202603/discovery/response/84213_20260302T040000000Z.json"]])
      expect(sent.first["authorization"]).to start_with("AWS4-HMAC-SHA256 Credential=AKIA/")
    end

    it "raises when the bucket refuses" do
      allow(client).to receive(:request).and_return(Net::HTTPNotFound.new("1.1", "404", "no"))

      expect { archive.fetch(uri) }.to raise_error(EdiGem::ArchiveFailed, /answered 404/)
    end

    # AWS's retry guidance: 500, 502, 503 and 504 are transient, 503 SlowDown and 429 throttling.
    { "500" => true, "502" => true, "503" => true, "504" => true, "429" => true,
      "404" => false, "403" => false, "400" => false }.each do |status, retryable|
      it "says whether a read answered #{status} may pass later (#{retryable})" do
        answer = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new("1.1", status, "x")
        allow(client).to receive(:request).and_return(answer)

        expect { archive.fetch(uri) }
          .to raise_error(EdiGem::ArchiveFailed, /answered #{status}/) { |failed| expect(failed.retryable?).to eq(retryable) }
      end
    end

    # One per family S3#reach calls a network failure; TLS is retried by choice, see NETWORK_ERRORS.
    [Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, Errno::ECONNRESET,
     Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Errno::EPIPE, IOError, EOFError,
     OpenSSL::SSL::SSLError].each do |kind|
      it "says a read that failed on the network with #{kind} may pass later" do
        allow(client).to receive(:request).and_raise(kind)

        expect { archive.fetch(uri) }
          .to raise_error(EdiGem::ArchiveFailed, /could not be reached \(#{kind}\)/) { |failed| expect(failed).to be_retryable }
      end
    end

    [Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError].each do |kind|
      it "says a read whose answer was not readable HTTP (#{kind}) will not pass by asking again" do
        allow(client).to receive(:request).and_raise(kind)

        expect { archive.fetch(uri) }
          .to raise_error(EdiGem::ArchiveFailed, /no readable HTTP \(#{kind}\)/) { |failed| expect(failed).to_not be_retryable }
      end
    end

    # A defect in the call is not an archive failure: it reaches the caller's own error path rather
    # than reading as a missing body.
    [TypeError, NoMethodError, ArgumentError].each do |kind|
      it "lets #{kind} from the client through as itself, not as ArchiveFailed" do
        allow(client).to receive(:request).and_raise(kind)

        expect { archive.fetch(uri) }.to raise_error(kind) { |raised| expect(raised).to_not be_a(EdiGem::ArchiveFailed) }
      end
    end

    it "refuses an object in another bucket, as a failure asking again will not change" do
      expect { archive.fetch("s3://elsewhere/raw/x.json") }
        .to raise_error(EdiGem::ArchiveFailed, %r{not in s3://warehouse}) { |failed| expect(failed).to_not be_retryable }
    end

    it "sends nothing for an object in another bucket" do
      expect { archive.fetch("s3://elsewhere/raw/x.json") }.to raise_error(EdiGem::ArchiveFailed)

      expect(sent).to be_empty
    end
  end

  describe "the connection it builds when none is handed to it" do
    let(:built) { instance_double(Net::HTTP, request: response) }

    before do
      allow(built).to receive(:use_ssl=)
      allow(built).to receive(:open_timeout=)
      allow(built).to receive(:read_timeout=)
      allow(Net::HTTP).to receive(:new).and_return(built)
    end

    it "reaches the bucket's own host over TLS, under the timeout it was given" do
      described_class.new(template: "s3://warehouse/raw/$DIRECTION", region: "us-west-2", timeout: 5,
                          access_key_id: "A", secret_access_key: "s")
                     .keep(exchange, clearinghouse: :stedi, feature: :discovery, name: "1")

      expect(Net::HTTP).to have_received(:new).with("warehouse.s3.us-west-2.amazonaws.com", 443)
      expect(built).to have_received(:use_ssl=).with(true)
      expect(built).to have_received(:open_timeout=).with(5)
      expect(built).to have_received(:read_timeout=).with(5)
    end
  end
end
