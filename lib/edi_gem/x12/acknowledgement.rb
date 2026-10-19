# frozen_string_literal: true

module EdiGem
  module X12
    # A 999 functional acknowledgement, read for whether it refused the transmission. It
    # carries no AAA, so without this a refused transmission would read as no coverage.
    class Acknowledgement
      # Verdict and reason elements: IK5 for the transaction, AK9 for the group.
      VERDICTS = { "IK5" => %w[IK501 IK502], "AK9" => %w[AK901 AK905] }.freeze

      # R rejected, M its authentication code failed, W it failed validity tests, X it could not
      # be read after decryption. A and E are accepted, E with errors noted.
      REFUSED = %w[R M W X].freeze

      DESCRIPTION = "999 rejected the transmission"

      # Anything that addresses X12 segments: a Document::X12, or an envelope carrying one.
      def initialize(document)
        @document = document
      end

      # One envelope-lane Rejection, or none.
      def rejections
        reasons = VERDICTS.flat_map do |id, (verdict, reason)|
          @document.records(id).select { |record| REFUSED.include?(record.value(verdict)) }
                   .map { |record| record.value(reason) }
        end
        return [] if reasons.empty?

        [Rejection.new(level: :envelope, code: reasons.compact.first, description: DESCRIPTION,
                       location: segment_in_error)]
      end

      private

      # IK3 names the segment and loop in error. IK4 is not read: it copies the bad value, which
      # can be PHI.
      def segment_in_error
        segment = @document.records("IK3").first
        segment && [segment.value("IK303"), segment.value("IK301")].compact.join("/")
      end
    end
  end
end
