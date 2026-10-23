# frozen_string_literal: true

require "json"
require "net/http"
require "set"

module EdiGem
  module Source
    class Mock < Stedi
      # Stands where Net::HTTP would for discovery, answering as Stedi does: a POST starts one, a
      # GET by id collects a pending one. Answers are Net::HTTP responses, with Stedi's HTTP
      # statuses, so the Transport reads them as it reads Stedi's.
      class Client
        # Seconds a 409 asks to wait, as Stedi's Retry-After does.
        IN_FLIGHT_RETRY_AFTER = "1"

        # Scenarios answered with an HTTP failure, in Stedi's error shape (429 has its own).
        FAILURES = {
          invalid: Reply.new(400, { "error" => "ValidationError", "message" => "The request body is invalid." }),
          forbidden: Reply.new(403, { "message" => "Forbidden" }),
          in_flight: Reply.new(409, { "error" => "Conflict",
                                      "message" => "A request with this idempotency key is in progress." },
                               { "retry-after" => IN_FLIGHT_RETRY_AFTER }),
          key_reused: Reply.new(422, { "error" => "UnprocessableEntity",
                                       "message" => "This idempotency key was used with a different request." }),
          throttled: Reply.new(429, { "message" => "The request can't be submitted because the sender's " \
                                                   "submission has been throttled: CUSTOMER_LIMIT",
                                      "code" => "TOO_MANY_REQUESTS" }),
          server_error: Reply.new(500, { "error" => "InternalServerError", "message" => "Internal server error." }),
          unavailable: Reply.new(503, { "error" => "ServiceUnavailable", "message" => "Service unavailable." }),
          gateway_timeout: Reply.new(504, { "error" => "GatewayTimeout", "message" => "Gateway timeout." })
        }.freeze

        # Stedi keeps a discovery's result for 30 days; an id it no longer has, or never had, is a 404.
        NOT_FOUND = Reply.new(404, { "error" => "NotFound", "message" => "Not found." }).freeze

        # `answers` builds the bodies.
        def initialize(answers:)
          @answers = answers
          @throttled_keys = Set.new
        end

        def request(request)
          return collected(request.uri.path.split("/").last) if request.method == "GET"

          asked(request)
        end

        private

        def asked(request)
          body = JSON.parse(request.body)
          return FAILURES.fetch(:invalid).to_net_http unless Answers.valid?(body)

          scenario = Scenario.new(body.dig("subscriber", "lastName"))
          failed(scenario.name, request["Idempotency-Key"]) ||
            @answers.discovery(body, scenario).reply.to_net_http
        end

        def failed(name, key)
          raise Net::ReadTimeout, "mock discovery timed out" if name == :timeout
          return throttled_once(key) if name == :throttled_once

          FAILURES[name]&.to_net_http
        end

        # Throttled the first time a key is sent, answered the next.
        def throttled_once(key)
          FAILURES.fetch(:throttled).to_net_http if @throttled_keys.add?(key)
        end

        def collected(discovery_id)
          answer = @answers.resolved(discovery_id)
          return NOT_FOUND.to_net_http unless answer

          answer.reply.to_net_http
        end
      end
    end
  end
end
