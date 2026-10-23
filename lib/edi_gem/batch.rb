# frozen_string_literal: true

module EdiGem
  # A batch of eligibility checks submitted to a source's batch endpoint and collected later.
  # Source::Base#submit_batch, #batch_status and #batch_checks return these objects.
  class Batch
    # Inquiries keyed by the identifier each answer comes back under. A Hash is taken as given;
    # an Array is keyed by position, which correlates within one submission only. Never keyed by
    # the question itself: two people can ask an identical question.
    def self.keyed(inquiries)
      return inquiries if inquiries.is_a?(Hash)

      inquiries.each_with_index.to_h { |inquiry, index| [index.to_s, inquiry] }
    end

    # What a batch endpoint returned on acceptance: an id to poll, not answers. Store the id
    # before the submitting job ends.
    class Submission
      attr_reader :id, :submitted_at, :count, :exchange

      def self.from(body, count:, exchange: nil)
        new(id: body["batchId"], submitted_at: body["submittedAt"], count: count,
            exchange: exchange)
      end

      def initialize(id:, submitted_at: nil, count: nil, exchange: nil)
        @id = id
        @submitted_at = submitted_at
        @count = count
        @exchange = exchange
      end
    end

    # How far along a batch is. Counts and a state, never coverage.
    class Status
      # VALIDATION_FAILED is terminal: no payer was asked and nothing more will arrive.
      FINISHED = %w[COMPLETED COMPLETED_WITH_ERRORS VALIDATION_FAILED].freeze

      FIELDS = { id: "id", name: "name", state: "status", total: "totalCount",
                 succeeded: "successCount", failed: "errorCount",
                 in_progress: "inProgressCount", validated: "validatedCount",
                 validation_failed: "validationFailedCount", max_retry_hours: "maxRetryHours",
                 created_at: "createdAt", updated_at: "updatedAt" }.freeze

      FIELDS.each_key { |field| attr_reader field }

      attr_reader :exchange

      def self.from(body, exchange: nil)
        new(exchange: exchange, **FIELDS.transform_values { |key| body[key] })
      end

      def initialize(exchange: nil, **fields)
        @exchange = exchange
        FIELDS.each_key { |field| instance_variable_set(:"@#{field}", fields[field]) }
      end

      # Where a batch has got to, by Stedi's status. Any status not finished is still in progress:
      # Stedi keeps retrying a silent payer for hours.
      PROGRESS = { "COMPLETED" => :completed, "COMPLETED_WITH_ERRORS" => :completed_with_errors,
                   "VALIDATION_FAILED" => :validation_failed }.freeze

      # Whether the checks are worth reading yet.
      def finished? = FINISHED.include?(@state)

      # `state` as a symbol, so a caller never reads Stedi's strings: :in_progress, :completed,
      # :completed_with_errors, or :validation_failed (no payer was asked, so no answers to read).
      def progress = PROGRESS.fetch(@state, :in_progress)
    end

    # One page of a batch's checks. A nil `next_page_token` is the only sign the listing is
    # complete; an empty page is not.
    class Checks
      attr_reader :items, :next_page_token, :exchange

      # `stored` is what the archive kept for each item, in the items' order, or nil.
      def self.from(body, exchange: nil, stored: nil)
        items = Array(body["items"]).each_with_index.map do |item, index|
          Check.new(item, stored: stored&.at(index))
        end
        new(items: items, next_page_token: body["nextPageToken"], exchange: exchange)
      end

      def initialize(items:, next_page_token: nil, exchange: nil)
        @items = items
        @next_page_token = next_page_token
        @exchange = exchange
      end

      def size = @items.length

      def more? = !@next_page_token.nil?
    end

    # One page of a batch's full answers, read and paged like Checks.
    class Answers < Checks; end

    # One finished check's full answer, under the identifier it was sent with.
    class Answer
      include Concealed

      attr_reader :identifier, :response

      def initialize(identifier:, response:)
        @identifier = identifier
        @response = response
      end

      # The response holds PHI, so only its state is printed.
      def concealed_inspect = "#<#{self.class} #{response.state}>"
    end

    # One check inside a batch. `state` is whether the source finished asking; `result` is what
    # the payer said. A COMPLETED check with an INACTIVE result is an answer; a
    # COMPLETED_WITH_ERRORS check is not.
    class Check
      include Concealed

      ACTIVE = "ACTIVE"
      DONE = %w[COMPLETED COMPLETED_WITH_ERRORS VALIDATION_FAILED].freeze

      # Where the archive filed this item's raw answer (an Archive::Stored), when the page was
      # read with `archive:`; nil otherwise.
      attr_reader :stored

      def initialize(attributes, stored: nil)
        @attributes = attributes || {}
        @stored = stored
      end

      # The item as the vendor sent it, parsed. Holds PHI.
      def raw = @attributes

      def state = @attributes["state"]

      def eligibility = @attributes.dig("additionalInfo", "eligibility") || {}

      def result = eligibility["eligibilityCheckResult"]

      def identifier = eligibility["submitterTransactionIdentifier"]

      def payer_code = eligibility["payerId"]

      def member_id = eligibility["subscriberMemberId"]

      def settled? = DONE.include?(state)

      # The source finished asking without error. A completed check with no answer in it is the
      # source's doing, not the payer's.
      def completed? = state == DONE.first

      def active? = result == ACTIVE

      # Holds PHI, so only the state and result are printed.
      def concealed_inspect = "#<#{self.class} #{state} #{result}>"
    end
  end
end
