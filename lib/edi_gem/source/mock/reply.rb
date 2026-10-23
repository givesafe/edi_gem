# frozen_string_literal: true

require "json"
require "net/http"

module EdiGem
  module Source
    class Mock < Stedi
      # One HTTP answer the mock gives: Stedi's status code, its JSON body and any headers, handed
      # to the Transport as the Net::HTTP response Stedi's would be.
      Reply = Struct.new(:code, :body, :headers) do
        def initialize(code, body, headers = {}) = super

        def to_net_http
          status = code.to_s
          response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status).new("1.1", status, "")
          { "content-type" => "application/json" }.merge(headers).each { |name, value| response[name] = value }
          response.instance_variable_set(:@body, JSON.generate(body))
          response.instance_variable_set(:@read, true)
          response
        end
      end
    end
  end
end
