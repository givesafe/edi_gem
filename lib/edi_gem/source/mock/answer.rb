# frozen_string_literal: true

require "securerandom"

module EdiGem
  module Source
    class Mock < Stedi
      # One discovery answer, as Stedi's body: its status, the plans found and Stedi's errors and
      # warnings, under the discovery's id. Answers chooses what a discovery answers; this knows how
      # Stedi spells it.
      Answer = Struct.new(:status, :discovery_id, :items, :errors, :warnings, keyword_init: true) do
        # `discovery_id` is the id Stedi gave the discovery, or nil for a new one.
        def initialize(status:, discovery_id: nil, items: [], errors: [], warnings: nil)
          super(status: status, discovery_id: discovery_id || "mock-#{SecureRandom.uuid}", items: items,
                errors: errors, warnings: warnings)
        end

        # Stedi labels every discovery "production", whatever the key, and traces each answer.
        def body
          { "meta" => { "applicationMode" => "production", "traceId" => "mock-#{SecureRandom.hex(6)}" },
            "discoveryId" => discovery_id, "status" => status,
            "coveragesFound" => (items.size unless status == Stedi::Responses::PENDING), "items" => items,
            "errors" => errors, "warnings" => warnings }.compact
        end

        # A pending discovery is answered 202, as Stedi answers one it is still working on.
        def reply = Reply.new(status == Stedi::Responses::PENDING ? 202 : 200, body)
      end
    end
  end
end
