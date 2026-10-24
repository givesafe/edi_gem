# frozen_string_literal: true

module EdiGem
  module Source
    class Stedi < Base
      # Turns one exchange into a Response: picks the schema, derives the state, and archives the
      # raw bodies when asked.
      class Responses
        # A discovery's status. COMPLETE with no items is a final answer: no coverage was found.
        PENDING = "PENDING"
        COMPLETE = "COMPLETE"
        # The vendor gave up on the request. Nothing in it is an answer, so it is a Fault, raised
        # after the body is filed.
        ERROR = "ERROR"
        # Where a batch results item carries the identifier it was sent with.
        IDENTIFIER = "submitterTransactionIdentifier"
        # The feature a request kept and never sent is filed under (Stedi#keep_question), apart from
        # those Stedi was sent.
        KEPT = :discovery_kept

        # `directory` is the source's payer directory, which each Response's plans ask for their
        # payer's ID.
        def initialize(clearinghouse:, archive: nil, directory: nil)
          @clearinghouse = clearinghouse
          @archive = archive
          @directory = directory
        end

        # Checked before anything is sent, so a billed answer is never received and then lost.
        # `filing` is `{ name: "stem", **placeholder_values }`.
        def ensure_archivable(filing)
          return unless filing

          if @archive.nil?
            raise ArchiveNotConfigured,
                  "this send asked to be archived and no archive is configured -- set " \
                  "EDI_ARCHIVE_TEMPLATE, or pass archive: to the source"
          end

          raise ArgumentError, "archive: needs a name: to file the bodies under" if
            filing[:name].to_s.empty?
        end

        # Files a request `body` that is never sent, as the one `url` would have been sent, and returns
        # where (a Stored's request_uri).
        def keep_unsent(body, url:, archive:)
          ensure_archivable(archive)
          exchange = Exchange.new(method: :post, url: url, request_body: JSON.generate(body), started_at: Time.now)
          kept(exchange, KEPT, archive).request_uri
        end

        # `body` is passed by calls whose answer carries a status (discovery); an eligibility
        # check is always settled when it returns.
        def from(exchange, schema:, feature:, handle: nil, body: nil, archive: nil)
          payload = Payload.new(body: exchange.response_body, dialect: :json)
          reading = Reading.new(document: payload.document, schema: Schema.fetch(schema))
          status = body && body["status"]
          stored = (kept(exchange, feature, archive) if archive)
          refuse_error(exchange, status)

          Response.new(**reading.parts, payload: payload, exchanges: [exchange],
                                        handle: handle, state: (:pending if status == PENDING),
                                        settled: status.nil? || status == COMPLETE,
                                        stored: stored, directory: @directory)
        end

        # Files each item of a batch page as its own object, named `<name>_<identifier>`, and
        # returns what the archive kept for each, in the items' order (nil when not asked to).
        # Every name is checked before the first write, so a page is filed whole or not at all.
        def keep_items(exchange, body, feature:, archive:)
          return unless archive

          items = Array(body["items"])
          names = items.map { |item| item_name(archive[:name], Batch::Check.new(item).identifier) }
          items.zip(names).map do |item, name|
            kept(item_exchange(exchange, item), feature, archive.merge(name: name))
          end
        end

        # Each item of a batch results page as its own Response, under the identifier it was sent
        # with. Filed as keep_items files a page: every name is checked before the first write.
        def results(exchange, body, schema:, feature:, archive:)
          items = Array(body["items"])
          names = items.map { |item| item_name(archive[:name], item[IDENTIFIER]) if archive }
          items.zip(names).map do |item, name|
            response = from(item_exchange(exchange, item), schema: schema, feature: feature,
                                                           archive: (archive.merge(name: name) if name))
            Batch::Answer.new(identifier: item[IDENTIFIER], response: response)
          end
        end

        private

        def refuse_error(exchange, status)
          raise Fault.new(kind: :vendor_error, source: @clearinghouse, status: exchange.status) if status == ERROR
        end

        # Neither the stem nor the identifier is named in the error: both are identifiers.
        def item_name(stem, identifier)
          name = "#{stem}_#{identifier}"
          return name unless identifier.to_s.empty? || !name.match?(Archive::SAFE_NAME)

          raise ArgumentError, "a batch item cannot be filed under that name and its identifier"
        end

        # One item of a page, as the exchange the archive files: the page's call, with the item
        # (as parsed, then written again) for a body.
        def item_exchange(page, item)
          Exchange.new(method: page.method, url: page.url, status: page.status,
                       response_body: JSON.generate(item), started_at: page.started_at)
        end

        def kept(exchange, feature, filing)
          @archive.keep(exchange, clearinghouse: @clearinghouse, feature: feature,
                                  name: filing[:name], values: filing.except(:name))
        end
      end
    end
  end
end
