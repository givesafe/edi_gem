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

        def initialize(clearinghouse:, archive: nil)
          @clearinghouse = clearinghouse
          @archive = archive
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

        # `body` is passed by calls whose answer carries a status (discovery); an eligibility
        # check is always settled when it returns.
        def from(exchange, schema:, feature:, handle: nil, body: nil, archive: nil)
          payload = Payload.new(body: exchange.response_body, dialect: :json)
          reading = Reading.new(document: payload.document, schema: Schema.fetch(schema))
          status = body && body["status"]
          stored = (kept(exchange, feature, archive) if archive)
          refuse_error(exchange, status)

          Response.new(benefits: reading.benefits, rejections: reading.rejections,
                       details: reading.details, payload: payload, exchanges: [exchange],
                       handle: handle, state: (:pending if status == PENDING),
                       settled: status.nil? || status == COMPLETE,
                       stored: stored)
        end

        # Files each item of a batch page as its own object, named `<name>_<identifier>`, and
        # returns what the archive kept for each, in the items' order (nil when not asked to).
        # Every name is checked before the first write, so a page is filed whole or not at all.
        def keep_items(exchange, body, feature:, archive:)
          return unless archive

          items = Array(body["items"])
          names = items.map { |item| item_name(archive[:name], item) }
          items.zip(names).map do |item, name|
            kept(item_exchange(exchange, item), feature, archive.merge(name: name))
          end
        end

        private

        def refuse_error(exchange, status)
          raise Fault.new(kind: :vendor_error, source: @clearinghouse, status: exchange.status) if status == ERROR
        end

        # Neither the stem nor the identifier is named in the error: both are identifiers.
        def item_name(stem, item)
          identifier = Batch::Check.new(item).identifier
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
