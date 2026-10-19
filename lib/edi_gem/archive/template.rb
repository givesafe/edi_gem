# frozen_string_literal: true

module EdiGem
  class Archive
    # Where the caller wants a body to land, written as a path with placeholders in it.
    #
    #   s3://bucket/edi/$CLEARINGHOUSE/$YYYYMM/$FEATURE/$DIRECTION
    #   file:///var/edi/$YYYYMMDD/$FEATURE/$DIRECTION
    #
    # The caller decides the layout. The gem supplies CLEARINGHOUSE, FEATURE, DIRECTION and the
    # date placeholders; any other placeholder is filled from the values passed with each body.
    class Template
      # `$NAME`, matched greedily so `$YYYYMM` is one placeholder.
      PLACEHOLDER = /\$([A-Z_]+[A-Z0-9_]*)/
      DATED = { "YYYY" => "%Y", "MM" => "%m", "DD" => "%d",
                "YYYYMM" => "%Y%m", "YYYYMMDD" => "%Y%m%d" }.freeze
      NAMED = %w[CLEARINGHOUSE FEATURE DIRECTION].freeze
      SUPPLIED = (NAMED + DATED.keys).freeze

      # Which half of the exchange a path is for.
      REQUEST = "request"
      RESPONSE = "response"

      # Characters allowed outside placeholders, so the path signs as spelled.
      SAFE = %r{\A[A-Za-z0-9\-._~/]*\z}

      S3 = %r{\As3://(?<bucket>[^/]+)(?:/(?<path>.*))?\z}
      FILE = %r{\Afile://(?<path>/.*)\z}

      attr_reader :bucket, :path

      def initialize(text)
        raise ArgumentError, "an archive template is required" if text.to_s.empty?

        @text = text.to_s.sub(%r{/+\z}, "")
        @bucket, @path = split(@text)
        @caller_keys = @text.scan(PLACEHOLDER).flatten.uniq - SUPPLIED
        ensure_directions_separated
        ensure_spelled_safely
      end

      def to_s = @text

      # The placeholders the caller must fill.
      attr_reader :caller_keys

      # The folder for one half of an exchange. `at` is the exchange's start, read in UTC.
      def resolve(clearinghouse:, feature:, direction:, at:, values: {})
        supplied = DATED.transform_values { |format| at.utc.strftime(format) }
                        .merge("CLEARINGHOUSE" => clearinghouse.to_s, "FEATURE" => feature.to_s,
                               "DIRECTION" => direction.to_s)
        # The gem's own values win over caller values of the same name.
        filled = named(values).merge(supplied)
        @path.gsub(PLACEHOLDER) { filled.fetch(Regexp.last_match(1)) { missing(_1) } }
      end

      private

      def named(values)
        values.to_h { |key, value| [key.to_s.upcase, value.to_s] }
      end

      def missing(placeholder)
        raise ArgumentError,
              "#{placeholder} is in the archive template and was not supplied with this body -- " \
              "the caller owes #{@caller_keys.join(", ")}"
      end

      def split(text)
        return [S3.match(text)[:bucket], S3.match(text)[:path].to_s] if S3.match?(text)
        return [nil, FILE.match(text)[:path]] if FILE.match?(text)
        raise ArgumentError, "#{text} names a scheme this gem cannot write to" if text.include?("://")

        [nil, text]
      end

      # Without $DIRECTION the response would overwrite the request.
      def ensure_directions_separated
        return if @text.include?("$DIRECTION")

        raise ArgumentError,
              "an archive template must place $DIRECTION, or the request and the response " \
              "would be written over each other"
      end

      def ensure_spelled_safely
        return if @path.gsub(PLACEHOLDER, "").match?(SAFE)

        raise ArgumentError,
              "an archive path may only hold letters, digits, - . _ ~ / and placeholders"
      end
    end
  end
end
