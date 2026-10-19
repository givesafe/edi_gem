# frozen_string_literal: true

require "json"
require "time"

module EdiGem
  # Keeps the raw request and response bodies of an exchange, which only the gem holds.
  #
  # Each exchange is written as two objects, request and response, in separate folders laid out
  # by a Template. Implementations: S3 and Local.
  #
  # The bodies are PHI, and the caller-supplied name in each path is an identifier. Access to
  # the store is the caller's to control.
  class Archive
    # Where one exchange was written. `request_uri` is nil when the call carried no body.
    Stored = Struct.new(:request_uri, :response_uri, :bytes, keyword_init: true)

    # Sortable and to the millisecond, so a retry is a second object rather than an overwrite.
    STAMP = "%Y%m%dT%H%M%S%LZ"
    SAFE_NAME = /\A[A-Za-z0-9\-._~]+\z/

    # Credential fields a source may send inside a JSON body. Redacted before writing.
    SECRET_FIELDS = %w[portalPassword portalUsername].freeze
    REDACTED = "[redacted]"

    # Built from the environment, or nil when no template is configured.
    #
    #   EDI_ARCHIVE_TEMPLATE   s3://... with the standard AWS credential variables  -> S3
    #   EDI_ARCHIVE_TEMPLATE   file:///... or a bare path                           -> local
    def self.from_env(env: ENV)
      text = env["EDI_ARCHIVE_TEMPLATE"]
      return nil if text.to_s.empty?

      template = Template.new(text)
      return Local.new(template: template) if template.bucket.nil?

      S3.from_env(template: template, env: env)
    end

    attr_reader :template

    def initialize(template:)
      @template = template.is_a?(Template) ? template : Template.new(template)
    end

    # `clearinghouse` and `feature` fill the template's placeholders of those names. `name` is
    # the file's stem, chosen by the caller. `values` fills the template's other placeholders.
    def keep(exchange, clearinghouse:, feature:, name:, values: {})
      file = filename(exchange, name)
      shared = { clearinghouse: clearinghouse, feature: feature, values: values,
                 at: started(exchange) }
      request = write(exchange.request_body, file, **shared, direction: Template::REQUEST)
      response = write(exchange.response_body, file, **shared, direction: Template::RESPONSE)
      Stored.new(request_uri: request&.first, response_uri: response&.first,
                 bytes: [request, response].compact.sum(&:last))
    end

    private

    # `<name>_<timestamp>.json`.
    def filename(exchange, name)
      raise ArgumentError, "a name is required to file a body under" if name.to_s.empty?
      raise ArgumentError, "#{name} cannot be written as a file name" unless
        name.to_s.match?(SAFE_NAME)

      "#{name}_#{started(exchange).utc.strftime(STAMP)}.json"
    end

    # Dated from the exchange, not from now.
    def started(exchange)
      exchange.started_at or
        raise ArgumentError, "exchange has no started_at, so it cannot be filed by date"
    end

    def write(body, file, direction:, **resolving)
      return nil if body.nil?

      body = redact(body) if direction == Template::REQUEST
      [put("#{@template.resolve(direction: direction, **resolving)}/#{file}", body), body.bytesize]
    end

    # Implemented by each store: writes one body and returns its URI.
    def put(path, _body)
      raise NotImplementedError, "#{self.class} cannot write #{path}"
    end

    # Redacts SECRET_FIELDS in a JSON body. Other bodies are kept as sent.
    def redact(body)
      parsed = JSON.parse(body.to_s)
      return body unless parsed.is_a?(Hash)

      JSON.generate(parsed.merge(SECRET_FIELDS.select { |field| parsed.key?(field) }
                                              .to_h { |field| [field, REDACTED] }))
    rescue JSON::ParserError
      body
    end
  end
end
