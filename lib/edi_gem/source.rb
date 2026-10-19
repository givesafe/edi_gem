# frozen_string_literal: true

module EdiGem
  # Somewhere an inquiry can be sent, usually a clearinghouse.
  module Source
    # The contract every source implements, so a caller never branches on which source it holds.
    #
    # A subclass declares NAME and search_options, reports its capabilities, and overrides the
    # methods of each feature it supports. A feature method it does not override raises
    # FeatureNotSupported; check `supports?` first.
    class Base
      FEATURES = %i[eligibility discovery batch].freeze

      # Combinations of Subscriber fields the source matches on. An inquiry must carry every
      # field of at least one combination.
      def search_options
        raise NotImplementedError
      end

      # Which features this source implements: `{ eligibility:, discovery:, batch: }`.
      def capabilities
        { eligibility: false, discovery: false, batch: false }
      end

      def supports?(feature)
        capabilities.fetch(feature.to_sym) do
          raise ArgumentError, "unknown feature #{feature.inspect}; one of #{FEATURES.join(", ")}"
        end
      end

      # The feature methods below take the contract's keywords and raise until overridden.
      # rubocop:disable Lint/UnusedMethodArgument

      # One real-time eligibility check. Returns a Response.
      def eligibility(_inquiry, idempotency_key: nil, archive: nil)
        unsupported(:eligibility)
      end

      # An insurance discovery. Returns a Response, which may be `pending` with a handle.
      def discovery(_inquiry, idempotency_key: nil, archive: nil)
        unsupported(:discovery)
      end

      # Collects the answer to a pending discovery by its handle. Returns a Response.
      def resolve(_handle, archive: nil)
        unsupported(:discovery)
      end

      # Submits many eligibility checks as one batch. `inquiries` is a Hash of the caller's
      # identifier => Inquiry::Eligibility; an Array is keyed by position. Returns a
      # Batch::Submission.
      def submit_batch(_inquiries, name: nil, idempotency_key: nil, **_options)
        unsupported(:batch)
      end

      # A Batch::Status: progress counts, never coverage.
      def batch_status(_batch_id)
        unsupported(:batch)
      end

      # One Batch::Checks page. Pass the previous page's `next_page_token` to read the next.
      def batch_checks(_batch_id, page_token: nil, page_size: nil)
        unsupported(:batch)
      end
      # rubocop:enable Lint/UnusedMethodArgument

      private

      def unsupported(feature)
        raise FeatureNotSupported, "#{self.class.name} does not support #{feature}"
      end

      # Called before every send, so an inquiry that cannot match is never billed.
      def ensure_searchable(inquiry)
        return if inquiry.satisfies?(search_options)

        raise IdentifiersNotAccepted,
              "inquiry carries #{inquiry.subscriber.identifiers.join(", ")}; " \
              "#{self.class::NAME} matches on " \
              "#{search_options.map { |option| option.join(" + ") }.join(", ")}"
      end

      def payer_code_for(inquiry)
        code = inquiry.payer_code.to_s.strip
        raise PayerNotRouted, "the inquiry carries no payer code for #{self.class::NAME}" if
          code.empty?

        code
      end
    end
  end
end
