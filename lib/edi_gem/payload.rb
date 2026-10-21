# frozen_string_literal: true

module EdiGem
  # A response body and its dialect, which picks the Document that reads it. The bytes are kept
  # exactly as they arrived.
  class Payload
    include Concealed

    DIALECTS = %i[json x12 soap mime].freeze

    attr_reader :body, :dialect, :media_type

    def initialize(body:, dialect:, media_type: nil)
      raise ArgumentError, "unknown dialect #{dialect}" unless DIALECTS.include?(dialect.to_sym)

      @body = body
      @dialect = dialect.to_sym
      @media_type = media_type
    end

    def document
      @document ||= Document.for(self)
    end

    # Never prints the body.
    def concealed_inspect
      "#<#{self.class} #{@dialect} #{@body.to_s.bytesize} bytes>"
    end
  end
end
