# frozen_string_literal: true

module EdiGem
  class Response
    # Which of Response::STATES an answer is in, read from its benefits and refusals.
    class State
      OUR_FAULT_LEVELS = %i[transport envelope].freeze
      NOT_IDENTIFIED_CODES = %i[member_id_invalid name_mismatch subscriber_not_found
                                patient_not_found date_of_birth_mismatch
                                duplicate_subscriber].freeze

      def initialize(benefits:, rejections:, handle:, settled:)
        @benefits = benefits
        @rejections = rejections
        @handle = handle
        @settled = settled
      end

      # An empty answer with a handle is pending unless the source said it is settled; only a
      # settled empty answer is no_coverage.
      def name
        return :pending if pending?
        return :rejected if rejected?
        return :not_identified if not_identified?
        return :payer_silent if payer_silent?
        return :no_coverage if benefit_lines.empty?
        return :partial if @rejections.any?

        :complete
      end

      private

      def pending?
        !@settled && @handle && @benefits.empty? && @rejections.empty?
      end

      def rejected?
        @rejections.any?(&:about_provider?) || our_request_refused?
      end

      def payer_silent?
        rejections_at(:payer).any? || (benefit_lines.empty? && @rejections.any?)
      end

      def benefit_lines
        @benefits.select(&:line?)
      end

      def our_request_refused?
        @rejections.any? { |rejection| OUR_FAULT_LEVELS.include?(rejection.level) }
      end

      # The patient may be the subscriber or a dependent of one; either one not found is the same.
      def not_identified?
        %i[subscriber dependent].flat_map { |level| rejections_at(level) }
                                .any? { |rejection| NOT_IDENTIFIED_CODES.include?(rejection.code) }
      end

      def rejections_at(level)
        @rejections.select { |rejection| rejection.level == level }
      end
    end
  end
end
