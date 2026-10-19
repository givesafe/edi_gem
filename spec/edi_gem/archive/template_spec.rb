# frozen_string_literal: true

RSpec.describe EdiGem::Archive::Template do
  def folder(text, clearinghouse: :stedi, feature: :eligibility_check, direction: "request",
             values: {}, at: Time.utc(2026, 3, 2, 4, 0, 0))
    described_class.new(text).resolve(clearinghouse: clearinghouse, feature: feature,
                                      direction: direction, at: at, values: values)
  end

  # The gem supplies the values a path may be keyed on; the caller writes the order.
  describe "the layout, which is the caller's and not the gem's" do
    it "keys a folder on the clearinghouse, the month, the feature and the half" do
      expect(folder("s3://warehouse/raw/$CLEARINGHOUSE/$YYYYMM/$FEATURE/$DIRECTION"))
        .to eq("raw/stedi/202603/eligibility_check/request")
    end

    it "keys the same facts in any other order the caller asks for" do
      expect(folder("s3://warehouse/raw/$FEATURE/$CLEARINGHOUSE/$YYYYMM/$DIRECTION"))
        .to eq("raw/eligibility_check/stedi/202603/request")
    end

    it "leaves out whatever the template does not name" do
      expect(folder("s3://warehouse/raw/$YYYYMM/$DIRECTION")).to eq("raw/202603/request")
    end

    it "partitions by day when that is what was asked for" do
      expect(folder("s3://w/$YYYY/$MM/$DD/$DIRECTION")).to eq("2026/03/02/request")
      expect(folder("s3://w/$YYYYMMDD/$DIRECTION")).to eq("20260302/request")
    end

    it "names the vendor that was actually asked, not the one we usually ask" do
      expect(folder("s3://w/$CLEARINGHOUSE/$DIRECTION", clearinghouse: :office_ally))
        .to eq("office_ally/request")
    end

    it "separates a discovery from an eligibility check under the same template" do
      expect(folder("s3://w/$FEATURE/$DIRECTION", feature: :discovery)).to eq("discovery/request")
    end

    it "puts the answer somewhere the question is not" do
      expect(folder("s3://w/$FEATURE/$DIRECTION", direction: "response"))
        .to eq("eligibility_check/response")
    end

    it "dates on the UTC clock, not the one the sending process was reading" do
      evening = Time.new(2026, 3, 31, 20, 0, 0, "-08:00")

      expect(folder("s3://w/$YYYYMM/$DIRECTION", at: evening)).to eq("202604/request")
    end

    it "treats a trailing slash as decoration rather than as an empty segment" do
      expect(folder("s3://warehouse/raw/$FEATURE/$DIRECTION/")).to eq("raw/eligibility_check/request")
    end
  end

  # Any placeholder the gem does not supply is the caller's to fill on every body.
  describe "a placeholder the gem does not supply" do
    it "is filled from the values handed over with the body" do
      expect(folder("s3://w/$RUN_ID/$FEATURE/$DIRECTION", values: { run_id: 7 }))
        .to eq("7/eligibility_check/request")
    end

    it "is reported, so a caller can be told what it owes without reading the template" do
      template = described_class.new("s3://w/$RUN_ID/$REGION/$YYYYMM/$DIRECTION")

      expect(template.caller_keys).to eq(%w[RUN_ID REGION])
    end

    it "names itself when it was not supplied, rather than writing the word into the path" do
      expect { folder("s3://w/$RUN_ID/$DIRECTION") }
        .to raise_error(ArgumentError, /RUN_ID is in the archive template and was not/)
    end

    it "cannot be overridden by a caller value of the same name" do
      expect(folder("s3://w/$FEATURE/$DIRECTION", values: { feature: "anything" }))
        .to eq("eligibility_check/request")
    end
  end

  describe "where it points" do
    it "reads the bucket out of an s3 template" do
      template = described_class.new("s3://warehouse/raw/$FEATURE/$DIRECTION")

      expect(template.bucket).to eq("warehouse")
      expect(template.path).to eq("raw/$FEATURE/$DIRECTION")
    end

    it "reads a file:// template as an absolute local path and no bucket" do
      template = described_class.new("file:///var/edi/$FEATURE/$DIRECTION")

      expect(template.bucket).to be_nil
      expect(template.path).to eq("/var/edi/$FEATURE/$DIRECTION")
    end

    it "reads a bare path as local too, because that is what a bin script hands it" do
      expect(described_class.new("tmp/edi/$DIRECTION").bucket).to be_nil
    end
  end

  describe "what it refuses, and refuses when it is built" do
    it "refuses a template that is not there at all" do
      expect { described_class.new(nil) }.to raise_error(ArgumentError, /template is required/)
      expect { described_class.new("") }.to raise_error(ArgumentError, /template is required/)
    end

    # Without it the question and the answer resolve to one path and the second overwrites the
    # first, which leaves a row pointing at a body that is not the one it says.
    it "refuses a template that would write the answer over the question" do
      expect { described_class.new("s3://warehouse/raw/$FEATURE") }
        .to raise_error(ArgumentError, /must place \$DIRECTION/)
    end

    # The request that stores an object signs a raw path, so a space would be encoded once by the
    # URI and again by the signature, and S3 would refuse it naming neither.
    it "refuses a path spelled with a character S3 could not be asked for" do
      expect { described_class.new("s3://w/raw files/$DIRECTION") }
        .to raise_error(ArgumentError, /letters, digits/)
    end

    it "refuses a scheme it has no backend for" do
      expect { described_class.new("gs://warehouse/raw/$DIRECTION") }
        .to raise_error(ArgumentError, /scheme this gem cannot write to/)
    end
  end
end
