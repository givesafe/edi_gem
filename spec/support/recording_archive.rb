# frozen_string_literal: true

# An archive that remembers rather than writes, so a spec about a SOURCE can assert what it
# handed over without a bucket or a temporary directory. What the two real stores do with an
# exchange is asserted in their own specs.
class RecordingArchive < EdiGem::Archive
  Kept = Struct.new(:exchange, :clearinghouse, :feature, :name, :supplied, keyword_init: true)

  attr_reader :kept

  def initialize(template: "raw/$CLEARINGHOUSE/$FEATURE/$DIRECTION")
    super
    @kept = []
  end

  def keep(exchange, clearinghouse:, feature:, name:, values: {})
    @kept << Kept.new(exchange: exchange, clearinghouse: clearinghouse, feature: feature,
                      name: name, supplied: values)
    Stored.new(bytes: 1,
               request_uri: "s3://warehouse/#{feature}/request/#{name}.json",
               response_uri: "s3://warehouse/#{feature}/response/#{name}.json")
  end
end
