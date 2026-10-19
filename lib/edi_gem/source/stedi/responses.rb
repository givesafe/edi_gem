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
          Response.new(benefits: reading.benefits, rejections: reading.rejections,
                       details: reading.details, payload: payload, exchanges: [exchange],
                       handle: handle, state: (:pending if status == PENDING),
                       settled: status.nil? || status == COMPLETE,
                       stored: (kept(exchange, feature, archive) if archive))
        end

        private

        def kept(exchange, feature, filing)
          @archive.keep(exchange, clearinghouse: @clearinghouse, feature: feature,
                                  name: filing[:name], values: filing.except(:name))
        end
      end
    end
  end
end
