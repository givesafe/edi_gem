# frozen_string_literal: true

RSpec.describe EdiGem::Archive do
  describe ".from_env" do
    let(:credentials) do
      { "AWS_ACCESS_KEY" => "AKIA", "AWS_SECRET_KEY" => "secret" }
    end

    it "answers with nothing when the environment configures no archive" do
      expect(described_class.from_env(env: {})).to be_nil
      expect(described_class.from_env(env: { "EDI_ARCHIVE_TEMPLATE" => "" })).to be_nil
    end

    it "builds an S3 archive from an s3 template when the credentials are there" do
      archive = described_class.from_env(
        env: credentials.merge("EDI_ARCHIVE_TEMPLATE" => "s3://warehouse/raw/$FEATURE/$DIRECTION",
                               "AWS_REGION" => "us-west-2")
      )

      expect(archive).to be_a(EdiGem::Archive::S3)
      expect(archive.bucket).to eq("warehouse")
      expect(archive.region).to eq("us-west-2")
    end

    # A laptop with the template in its shell profile and no keys is the ordinary case, not a
    # broken one. Failing at load there would stop a developer running anything at all.
    it "answers with nothing when a bucket is named and the credentials are not there" do
      expect(described_class.from_env(env: { "EDI_ARCHIVE_TEMPLATE" => "s3://warehouse/raw/$DIRECTION" }))
        .to be_nil
    end

    it "falls back to the region AWS's own tools default to" do
      archive = described_class.from_env(
        env: credentials.merge("EDI_ARCHIVE_TEMPLATE" => "s3://w/raw/$DIRECTION")
      )

      expect(archive.region).to eq("us-east-1")
    end

    it "reads AWS_DEFAULT_REGION, which is what the CLI sets and the SDK does not" do
      archive = described_class.from_env(
        env: credentials.merge("EDI_ARCHIVE_TEMPLATE" => "s3://w/raw/$DIRECTION",
                               "AWS_DEFAULT_REGION" => "eu-west-1")
      )

      expect(archive.region).to eq("eu-west-1")
    end

    it "builds a local archive from a path template, which needs no credentials at all" do
      archive = described_class.from_env(env: { "EDI_ARCHIVE_TEMPLATE" => "file:///tmp/edi/$DIRECTION" })

      expect(archive).to be_a(EdiGem::Archive::Local)
      expect(archive.template.path).to eq("/tmp/edi/$DIRECTION")
    end

    # The template is checked at boot rather than at the first write.
    it "raises on an unusable template rather than waiting for a body to write" do
      expect { described_class.from_env(env: { "EDI_ARCHIVE_TEMPLATE" => "file:///t/$FEATURE" }) }
        .to raise_error(ArgumentError, /must place \$DIRECTION/)
    end
  end

  it "takes a template as text, so a caller need not build one to configure an archive" do
    expect(described_class.new(template: "s3://w/$FEATURE/$DIRECTION").template)
      .to be_a(EdiGem::Archive::Template)
  end

  describe "on its own, naming a port rather than a backend" do
    subject(:archive) { described_class.new(template: "raw/$FEATURE/$DIRECTION") }

    let(:exchange) do
      EdiGem::Exchange.new(method: :post, url: "https://x.test", status: 200,
                           request_body: "{}", response_body: "{}",
                           started_at: Time.utc(2026, 3, 2))
    end

    it "cannot write a body" do
      expect { archive.keep(exchange, clearinghouse: :stedi, feature: :discovery, name: "1") }
        .to raise_error(NotImplementedError, %r{cannot write raw/discovery/request/1_.*\.json})
    end

    it "cannot read a body back" do
      expect { archive.fetch("raw/discovery/response/1.json") }
        .to raise_error(NotImplementedError, %r{cannot read raw/discovery/response/1\.json})
    end
  end
end
