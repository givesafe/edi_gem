# frozen_string_literal: true

require "pp"

# Every object holding a secret or PHI prints only names, sizes and states, unless EdiGem.reveal
# is on, which a host turns on only where there is no real member data and no production key.
RSpec.describe EdiGem::Concealed do
  let(:api_key) { "sk_test_8f2c1d" }
  let(:aws_secret) { "wJalrXUtnFEMI-example" }
  let(:password) { "pw-4821" }
  let(:body) { '{"subscriber":{"memberId":"9AB12345678","firstName":"Jane"}}' }

  let(:objects) do
    {
      source: EdiGem::Source::Stedi.new(api_key: api_key, archive: nil),
      connection: EdiGem::Source::Connection.new(policy: EdiGem::Policy.for(:stedi),
                                                 headers: { "Authorization" => api_key }),
      archive: EdiGem::Archive::S3.new(template: "s3://bucket/edi/$FEATURE/$DIRECTION",
                                       region: "us-west-2", access_key_id: "AKIAEXAMPLE",
                                       secret_access_key: aws_secret),
      signature: EdiGem::Archive::Signature.new(access_key_id: "AKIAEXAMPLE", region: "us-west-2",
                                                secret_access_key: aws_secret),
      request: EdiGem::Core::Request.new(payload: "NM1*IL*1*DOE*JANE~", sender: "S", receiver: "R",
                                         username: "portal-user", password: password),
      document: EdiGem::Document::Json.new(body),
      record: EdiGem::Document::Record.new({ "memberId" => "9AB12345678" }),
      response: EdiGem::Response.new(details: { trace_id: "T1", member_name: "Jane" })
    }
  end

  let(:values) { [api_key, aws_secret, password, "9AB12345678", "Jane", "JANE"] }

  def printed(object) = object.inspect

  after { EdiGem.reveal = false }

  context "WHEN EdiGem.reveal is off, the default" do
    it "prints no secret and no PHI from any of them" do
      objects.each_value do |object|
        expect(values.none? { |value| printed(object).include?(value) }).to be(true), printed(object)
      end
    end

    it "prints none through pp either, which is what a console shows" do
      objects.each_value do |object|
        expect(values.none? { |value| object.pretty_inspect.include?(value) }).to be(true)
      end
    end

    it "says what each is, without its values" do
      expect(objects.transform_values { |object| printed(object) }).to include(
        source: "#<EdiGem::Source::Stedi>",
        connection: "#<EdiGem::Source::Connection headers=Authorization>",
        archive: a_string_including("@signature=#<EdiGem::Archive::Signature us-west-2>"),
        signature: "#<EdiGem::Archive::Signature us-west-2>",
        request: "#<EdiGem::Core::Request X12_270_Request_005010X279A1 RealTime 18 bytes>",
        document: "#<EdiGem::Document::Json>",
        record: "#<EdiGem::Document::Record>",
        response: "#<EdiGem::Response no_coverage benefits=0 rejections=0 details=trace_id,member_name>"
      )
    end

    it "stays off for anything but true" do
      EdiGem.reveal = "true"
      expect(EdiGem.reveal?).to be(false)
    end
  end

  context "WHEN EdiGem.reveal is on" do
    before { EdiGem.reveal = true }

    it "prints each secret where it is held" do
      expect(printed(objects[:source])).to include(api_key)
      expect(printed(objects[:connection])).to include(api_key)
      expect(printed(objects[:signature])).to include(aws_secret)
      expect(printed(objects[:request])).to include(password, "JANE")
    end

    it "prints the objects inside an object in full too" do
      expect(printed(objects[:archive])).to include(aws_secret)
    end

    it "prints PHI, including from the objects that hid it before" do
      expect(printed(objects[:document])).to include("9AB12345678", "Jane")
      expect(printed(objects[:record])).to include("9AB12345678")
      expect(printed(objects[:response])).to include("Jane")
      expect(printed(EdiGem::Subscriber.new(first_name: "Jane"))).to include("Jane")
      expect(printed(EdiGem::Payload.new(body: body, dialect: :json))).to include("9AB12345678")
    end

    it "prints through pp too, nested objects included" do
      expect(objects[:source].pretty_inspect).to include(api_key)
      expect(objects[:archive].pretty_inspect).to include(aws_secret)
    end
  end
end
