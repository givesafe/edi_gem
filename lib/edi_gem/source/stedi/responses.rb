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
        # The vendor gave up on the request, with HTTP 502. Without AAA refusals nothing in it is an
        # answer, so it is a Fault, raised after the body is filed.
        ERROR = "ERROR"
        # Where a batch results item carries the identifier it was sent with.
        IDENTIFIER = "submitterTransactionIdentifier"

        # `directory` is the source's payer directory, which each Response's plans ask for their
        # payer's ID. `policy` says what a failing HTTP status means (Fault.of_status).
        def initialize(clearinghouse:, policy:, archive: nil, directory: nil)
          @clearinghouse = clearinghouse
          @policy = policy
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

        # `body` is passed by calls whose answer carries a status (discovery); an eligibility
        # check is always settled when it returns.
        #
        # A write the archive fails (ArchiveFailed) does not lose the answer: it was billed and is
        # read in full, so the Response comes back unstored, carrying the failure as
        # `archive_failure` for the caller to report. Nothing here retries the write.
        def from(exchange, schema:, feature:, handle: nil, body: nil, archive: nil)
          payload = Payload.new(body: exchange.response_body, dialect: :json)
          status = body && body["status"]
          reading = read(exchange, status) { Reading.new(document: payload.document, schema: Schema.fetch(schema)) }
          stored, archive_failure = filed(exchange, feature, archive)
          refuse_error(exchange, status, reading)

          Response.new(**reading.parts, payload: payload, exchanges: [exchange],
                                        handle: handle, state: (:pending if status == PENDING),
                                        settled: [nil, COMPLETE, ERROR].include?(status),
                                        stored: stored, archive_failure: archive_failure,
                                        directory: @directory)
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

        # The body as the block reads it. A failing HTTP status the transport let through
        # (Policy#answer_in_status?) is an answer only when its body holds Stedi's AAA refusals, read
        # as a success's are: a 400 with an AAA 79 is a payer Stedi couldn't connect to. Without one
        # it is the Fault its status means, as the transport raises it, and nothing is filed. A body
        # that isn't JSON holds none.
        def read(exchange, status)
          return yield unless exchange.failing_status?

          reading = begin
            yield
          rescue UnreadableBody
            nil
          end
          return reading if status == ERROR || refused_by_aaa?(reading)

          raise status_fault(exchange)
        end

        def refused_by_aaa?(reading) = reading&.rejections&.any?(&:aaa?)

        def status_fault(exchange)
          Fault.of_status(exchange.status, policy: @policy, path: URI(exchange.url).path)
        end

        def refuse_error(exchange, status, reading)
          return unless status == ERROR && reading.rejections.none?(&:aaa?)

          raise Fault.new(kind: :vendor_error, source: @clearinghouse, status: exchange.status)
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

        # [stored, nil] when the archive kept the bodies, [nil, failure] when it could not, and
        # [nil, nil] when the send did not ask to archive.
        def filed(exchange, feature, filing)
          return [nil, nil] unless filing

          [kept(exchange, feature, filing), nil]
        rescue ArchiveFailed => error
          [nil, error]
        end

        def kept(exchange, feature, filing)
          @archive.keep(exchange, clearinghouse: @clearinghouse, feature: feature,
                                  name: filing[:name], values: filing.except(:name))
        end
      end
    end
  end
end
