# frozen_string_literal: true

module EdiGem
  module Source
    class Stedi < Base
      # Stedi's batch eligibility: submit, follow the batch, and read each check's state and answer.
      module Batching
        # Up to 10,000 checks in one request, answered with a batch id. The price per check is the
        # same as a real-time check.
        #
        # `max_retry_hours` is how long Stedi keeps retrying a payer that does not respond (8 by
        # default, up to 24); a batch is not finished until that window closes.
        def submit_batch(inquiries, name: nil, idempotency_key: nil, max_retry_hours: nil)
          items = Batch.keyed(inquiries).map { |id, inquiry| batch_item(id, inquiry) }
          body = { items: items, name: name, maxRetryHours: max_retry_hours }.compact
          exchange = post(:batch_eligibility, body, key: idempotency_key)
          Batch::Submission.from(parse(exchange), count: items.length, exchange: exchange)
        end

        def batch_status(batch_id)
          exchange = get(:batch_status, "#{@policy.path_for(:batch_status)}/#{batch_id}")
          Batch::Status.from(parse(exchange), exchange: exchange)
        end

        # Every check in the batch, in whatever state each is in, including checks that failed
        # validation. A nil `next_page_token` is the only sign the listing is complete.
        #
        # `archive:` (`{ name: "stem" }`, as for a real-time check) files each item's raw answer as
        # its own object under `<stem>_<identifier>`; the Archive::Stored comes back on the item as
        # `check.stored`. An item with no identifier cannot be filed, and raises.
        #
        # `only:` (identifiers) keeps the items sent under those alone, so a caller that has taken
        # some answers already reads, and files, only the rest. nil keeps every item.
        def batch_checks(batch_id, page_token: nil, page_size: nil, archive: nil, only: nil)
          responses.ensure_archivable(archive)
          query = { pageToken: page_token, pageSize: page_size }.compact
          path = "#{@policy.path_for(:batch_checks)}/#{batch_id}/items"
          exchange = get(:batch_checks, query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}")
          body = kept_items(parse(exchange), only) { |item| Batch::Check.new(item).identifier }
          stored = responses.keep_items(exchange, body, feature: BATCH_CHECK, archive: archive)
          Batch::Checks.from(body, exchange: exchange, stored: stored)
        end

        # The full answer of every check in the batch that Stedi has finished, each read as a
        # real-time check is. batch_checks says whether a check is done; this is what it said. A check
        # still being retried is on no page yet, and one that failed validation never is.
        #
        # `archive:` files each item's answer under `<stem>_<identifier>`, and `only:` keeps the
        # items sent under those identifiers alone, as batch_checks does.
        def batch_results(batch_id, page_token: nil, page_size: nil, archive: nil, only: nil)
          responses.ensure_archivable(archive)
          query = { batchId: batch_id, pageToken: page_token, pageSize: page_size }.compact
          exchange = get(:batch_results, "#{@policy.path_for(:batch_results)}?#{URI.encode_www_form(query)}")
          body = kept_items(parse(exchange), only) { |item| item[Responses::IDENTIFIER] }
          items = responses.results(exchange, body, schema: NAME, feature: BATCH_RESULT, archive: archive)
          Batch::Answers.new(items: items, next_page_token: body["nextPageToken"], exchange: exchange)
        end

        private

        # The page with only the items whose identifier (the block's) is one of `only`; the page
        # token is kept, so the listing still pages on. The page is the parsed body, a Hash: choosing
        # its items is this call's, not the Hash's.
        # :reek:FeatureEnvy
        def kept_items(body, only)
          return body unless only

          wanted = only.map(&:to_s)
          body.merge("items" => Array(body["items"]).select { |item| wanted.include?(yield(item)) })
        end

        def batch_item(identifier, inquiry)
          ensure_searchable(inquiry)
          request(inquiry, payer_code: payer_code_for(inquiry)).batch_item(identifier)
        end
      end
    end
  end
end
