# frozen_string_literal: true

module EdiGem
  class Response
    # Which of Response::STATES an answer is in, read from its benefits and refusals.
    class State
      OUR_FAULT_LEVELS = %i[transport envelope].freeze
      NOT_IDENTIFIED = %i[held_differently not_on_this_id].freeze

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
        return :not_identified if NOT_IDENTIFIED.include?(person_refusal)
        return :payer_silent if payer_rejections.any?
        return without_lines if benefit_lines.empty?
        return :partial if @rejections.any?

        :complete
      end

      # The refusal that decided #name, read in the same order: one about our provider (which the
      # caller files apart) or the request; the person's, when the payer can't tell who they are; the
      # payer's, the one its next step turns on (refused as sent or our setup, then unreached); then
      # the person's that FINDINGS reads. Beside benefit lines (partial) the lines decided, and this
      # is the refusal about part of what was asked. nil with no refusal.
      def deciding_rejection
        refused_request || not_identified_refusal || payer_refusal || person_refusal_rejection || @rejections.first
      end

      private

      def pending?
        !@settled && @handle && @benefits.empty? && @rejections.empty?
      end

      def rejected?
        @rejections.any?(&:about_provider?) || our_request_refused?
      end

      # With no line, a refusal in the person's lane decides (PersonRefusal::FINDINGS): what we sent
      # is ours to fix, a death before the day is no coverage, and any other refusal is the payer's
      # silence. Beside lines, the same refusal is about part of what was asked (partial).
      def without_lines
        return :no_coverage if @rejections.empty? || person_refusal == :not_covered

        person_refusal == :our_fault ? :rejected : :payer_silent
      end

      def benefit_lines
        @benefits.select(&:line?)
      end

      def our_request_refused?
        @rejections.any? { |rejection| OUR_FAULT_LEVELS.include?(rejection.level) }
      end

      def refused_request
        @rejections.find(&:about_provider?) ||
          @rejections.find { |rejection| OUR_FAULT_LEVELS.include?(rejection.level) }
      end

      def not_identified_refusal
        person_refusal_rejection if NOT_IDENTIFIED.include?(person_refusal)
      end

      def payer_refusal
        payer_find { |rejection| rejection.resubmission_refused? || rejection.our_setup_refused? } ||
          payer_find(&:payer_unreached?) || payer_rejections.first
      end

      def payer_find(&) = payer_rejections.find(&)

      # The patient may be the subscriber or a dependent of one; a refusal in either lane is the same.
      def person_refusal
        PersonRefusal.finding_among(@rejections)&.first
      end

      def person_refusal_rejection
        PersonRefusal.refusal_among(@rejections)
      end

      # The payer lane, and in another lane a reason Stedi reads as the payer's (Rejection#about_payer?).
      def payer_rejections
        @rejections.select(&:about_payer?)
      end
    end
  end
end
