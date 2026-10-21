# frozen_string_literal: true

module EdiGem
  # One HTTP call, recorded verbatim: the bytes as sent and received. An inquiry can produce
  # several (a POST, then a GET for a pending answer).
  class Exchange
    include Concealed

    attr_reader :method, :url, :request_headers, :request_body,
                :status, :response_headers, :response_body,
                :started_at, :duration

    def initialize(method:, url:, request_headers: {}, request_body: nil,
                   status: nil, response_headers: {}, response_body: nil,
                   started_at: nil, duration: nil)
      @method = method
      @url = url
      @request_headers = request_headers
      @request_body = request_body
      @status = status
      @response_headers = response_headers
      @response_body = response_body
      @started_at = started_at
      @duration = duration
    end

    # Built from a net/http request and response.
    def self.from_http(request:, response:, started_at:, ended_at: Time.now)
      new(method: request.method.downcase.to_sym, url: request.uri.to_s,
          request_headers: request.each_header.to_h, request_body: request.body,
          status: response.code.to_i, response_headers: response.each_header.to_h,
          response_body: response.body,
          started_at: started_at, duration: ended_at - started_at)
    end

    def to_h
      { method: @method, url: @url,
        request_headers: @request_headers, request_body: @request_body,
        status: @status, response_headers: @response_headers, response_body: @response_body,
        started_at: @started_at&.iso8601, duration: @duration }
    end

    # Bodies hold PHI and headers hold credentials, so neither is ever printed.
    def concealed_inspect
      "#<#{self.class} #{@method.to_s.upcase} #{@url} -> #{@status}>"
    end
  end
end
