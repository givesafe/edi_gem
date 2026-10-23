# frozen_string_literal: true

RSpec.describe EdiGem::Error do
  describe "#code" do
    it "names a gem error by its class" do
      expect(EdiGem::CredentialMissing.new("portal_password is missing").code).to eq("credential_missing")
    end

    it "names a fault by its kind" do
      expect(EdiGem::Fault.new(kind: :timeout, source: :stedi).code).to eq("timeout")
    end
  end

  describe EdiGem::ArchiveFailed do
    it "is not retryable unless the raiser says so, so an unclassified failure is not asked again" do
      expect { raise EdiGem::ArchiveFailed, "s3://warehouse/x.json answered 418" }
        .to raise_error(EdiGem::ArchiveFailed) { |failed| expect(failed).to_not be_retryable }
    end

    it "is retryable when raised as one" do
      expect(EdiGem::ArchiveFailed.new("could not be reached", retryable: true)).to be_retryable
    end

    it "is still a gem error, named by its class" do
      failed = EdiGem::ArchiveFailed.new("answered 503", retryable: true)

      expect([failed, failed.code, failed.message]).to match([be_a(EdiGem::Error), "archive_failed", "answered 503"])
    end
  end
end
