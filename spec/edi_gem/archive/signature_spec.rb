# frozen_string_literal: true

RSpec.describe EdiGem::Archive::Signature do
  subject(:signature) do
    described_class.new(access_key_id: "AKIAIOSFODNN7EXAMPLE", region: "us-east-1",
                        secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
  end

  # AWS publishes a worked PUT Object example with every intermediate value and the final
  # signature. It is the only way to know a hand-rolled signature is right without spending a
  # real request to find out, and it is why the SDK is not a dependency here: the specification
  # is fixed and the answer is checkable.
  #
  #   https://docs.aws.amazon.com/AmazonS3/latest/API/sig-v4-header-based-auth.html
  describe "against the signature AWS publishes for its own worked example" do
    let(:headers) do
      signature.headers_for(
        method: :put, uri: URI.parse("https://examplebucket.s3.amazonaws.com/test$file.text"),
        body: "Welcome to Amazon S3.", now: Time.utc(2013, 5, 24),
        headers: { "date" => "Fri, 24 May 2013 00:00:00 GMT",
                   "x-amz-storage-class" => "REDUCED_REDUNDANCY" }
      )
    end

    it "produces the signature in the published example, digit for digit" do
      expect(headers["Authorization"])
        .to include("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd")
    end

    it "scopes the credential to the date, the region and s3" do
      expect(headers["Authorization"])
        .to include("Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request")
    end

    it "signs the caller's headers alongside the three it adds, in sorted order" do
      expect(headers["Authorization"])
        .to include("SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class")
    end

    it "hashes the payload, which S3 requires on the request as well as in the signature" do
      expect(headers["x-amz-content-sha256"])
        .to eq("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
    end

    it "states the date in the compact form the scope and the header have to agree on" do
      expect(headers["x-amz-date"]).to eq("20130524T000000Z")
    end
  end

  describe "the parts a worked example cannot reach" do
    let(:uri) { URI.parse("https://bucket.s3.us-west-2.amazonaws.com/eligibility/a.json") }

    def signed_path(path)
      signature.headers_for(method: :put, body: "",
                            uri: URI.parse("https://bucket.s3.us-east-1.amazonaws.com#{path}"),
                            now: Time.utc(2026, 1, 1))
               .fetch("Authorization")
    end

    it "names the host it is signing for, which S3 checks against the one it was reached on" do
      headers = signature.headers_for(method: :put, uri: uri, body: "{}")

      expect(headers["host"]).to eq("bucket.s3.us-west-2.amazonaws.com")
    end

    # A role's temporary credentials are refused without their token, and the token is signed --
    # sending it unsigned fails with the same message as sending it not at all.
    it "signs the session token when the credentials are temporary" do
      temporary = described_class.new(access_key_id: "ASIA", secret_access_key: "s",
                                      region: "us-east-1", session_token: "FQoGZXIvYXdz")

      headers = temporary.headers_for(method: :put, uri: uri, body: "{}")

      expect(headers["x-amz-security-token"]).to eq("FQoGZXIvYXdz")
      expect(headers["Authorization"]).to include("x-amz-security-token")
    end

    it "sends no token header at all on long-lived credentials" do
      headers = signature.headers_for(method: :put, uri: uri, body: "{}")

      expect(headers).not_to have_key("x-amz-security-token")
    end

    # `URI.encode_www_form_component` is the obvious escape and is wrong twice over here: it
    # writes a space as `+` and it escapes `~`. Both produce a canonical request that differs
    # from the one S3 builds, and the only symptom is a refused signature with no clue in it.
    #
    # A tilde left alone and a tilde written `%7E` are two different keys, so they must sign
    # differently. An escape that touched `~` would collapse them onto one signature.
    it "leaves a tilde alone rather than escaping it into a different key" do
      bare = signed_path("/a~b")
      encoded = signed_path("/a%7Eb")

      expect(bare).not_to eq(encoded)
    end

    # The caller's own Authorization would be signed and then overwritten by this method's, so
    # the signature would cover a header that was never sent.
    it "refuses to sign an Authorization header the caller supplied" do
      headers = signature.headers_for(method: :put, uri: uri, body: "{}",
                                      headers: { "Authorization" => "stale" })

      expect(headers["Authorization"]).to start_with("AWS4-HMAC-SHA256 Credential=")
      expect(headers["Authorization"]).not_to include("SignedHeaders=authorization")
    end

    it "reads the clock in UTC, which is the only zone AWS accepts" do
      expect(described_class.now.utc?).to be(true)
    end
  end
end
