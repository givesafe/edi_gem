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
        # Scenarios answered with an HTTP failure: status and body (Stedi's error shape; 429 has its own).
        FAILURES = {
          invalid: [400, { "error" => "ValidationError", "message" => "The request body is invalid." }],
          forbidden: [403, { "message" => "Forbidden" }],
          in_flight: [409, { "error" => "Conflict",
                             "message" => "A request with this idempotency key is in progress." }],
          key_reused: [422, { "error" => "UnprocessableEntity",
                              "message" => "This idempotency key was used with a different request." }],
          throttled: [429, { "message" => "The request can't be submitted because the sender's submission has been " \
                                          "throttled: CUSTOMER_LIMIT", "code" => "TOO_MANY_REQUESTS" }],
          server_error: [500, { "error" => "InternalServerError", "message" => "Internal server error." }],
          unavailable: [503, { "error" => "ServiceUnavailable", "message" => "Service unavailable." }],
          gateway_timeout: [504, { "error" => "GatewayTimeout", "message" => "Gateway timeout." }]
        }.freeze

        # Stedi keeps a discovery's result for 30 days; an id it no longer has, or never had, is a 404.
        NOT_FOUND = [404, { "error" => "NotFound", "message" => "Not found." }].freeze

        # Seconds a 409 asks to wait, as Stedi's Retry-After does.
        IN_FLIGHT_RETRY_AFTER = "1"

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
          return http_response(*FAILURES[:invalid]) unless @answers.valid?(body)

          scenario = Scenario.new(body.dig("subscriber", "lastName"))
          failed(scenario.name, request["Idempotency-Key"]) ||
            answered(@answers.discovery(body, scenario))
        end

        def failed(name, key)
          raise Net::ReadTimeout, "mock discovery timed out" if name == :timeout
          return throttled_once(key) if name == :throttled_once
          return unless FAILURES.key?(name)

          headers = name == :in_flight ? { "retry-after" => IN_FLIGHT_RETRY_AFTER } : {}
          http_response(*FAILURES.fetch(name), headers)
        end

        # Throttled the first time a key is sent, answered the next.
        def throttled_once(key)
          http_response(*FAILURES[:throttled]) if @throttled_keys.add?(key)
        end

        def collected(discovery_id)
          body = @answers.resolved(discovery_id)
          return http_response(*NOT_FOUND) unless body

          answered(body)
        end

        # A pending discovery is answered 202, as Stedi answers one it is still working on.
        def answered(body)
          http_response(body["status"] == Answers::PENDING ? 202 : 200, body)
        end

        def http_response(code, body, headers = {})
          response = Net::HTTPResponse::CODE_TO_OBJ.fetch(code.to_s).new("1.1", code.to_s, "")
          { "content-type" => "application/json" }.merge(headers).each { |name, value| response[name] = value }
          response.instance_variable_set(:@body, JSON.generate(body))
          response.instance_variable_set(:@read, true)
          response
        end
      end
    end
  end
end
