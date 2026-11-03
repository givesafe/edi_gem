# frozen_string_literal: true

module EdiGem
  module Source
    class Stedi < Base
      # Stedi's answers the archive kept, read again: nothing is sent to Stedi, so nothing is billed.
      module Archived
        # A discovery answer the archive kept (a Stored's response_uri), read again into a Response.
        # Nothing is sent to Stedi, so nothing is billed: the answer is the one already paid for.
        # Raises ArchiveNotConfigured with no archive, and ArchiveFailed when the body cannot be read:
        # `retryable?` is true when the archive could not be reached or answered that it is failing,
        # and false when the body is missing or refused, which asking again will not change.
        def archived_discovery(response_uri)
          raise ArchiveNotConfigured, "no archive is configured to read a discovery from" if @archive.nil?

          body = @archive.fetch(response_uri)
          exchange = Exchange.new(method: :get, url: response_uri, status: 200, response_body: body)
          parsed = Document::Json.parse(body)
          responses.from(exchange, schema: DISCOVERY_SCHEMA, handle: parsed["discoveryId"], body: parsed,
                                   feature: DISCOVERY)
        end

        # An eligibility answer the archive kept (a Stored's response_uri), read again into a Response
        # as archived_discovery reads a discovery: nothing is sent or billed, and it fails the same ways.
        def archived_eligibility(response_uri)
          raise ArchiveNotConfigured, "no archive is configured to read an eligibility answer from" if @archive.nil?

          body = @archive.fetch(response_uri)
          exchange = Exchange.new(method: :get, url: response_uri, status: 200, response_body: body)
          responses.from(exchange, schema: NAME, feature: ELIGIBILITY_CHECK)
        end

        # The common name for the archived readers, by the `kind` of answer kept (:eligibility or
        # :discovery), so a caller need not know the source.
        def archived(response_uri, kind:)
          case kind
          when :eligibility then archived_eligibility(response_uri)
          when :discovery then archived_discovery(response_uri)
          else raise ArgumentError, "no archived reader for #{kind.inspect}"
          end
        end
      end
    end
  end
end
