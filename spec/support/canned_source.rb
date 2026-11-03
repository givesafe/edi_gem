# frozen_string_literal: true

# A vendor that answers from a file instead of over the network.
#
# It is injected through Source::Stedi's own `transport:` seam, which is the seam the real
# transport uses, so a call through it still builds the request, chooses the schema, reads the
# response and derives the state. Only the socket is absent.
module CannedSource
  FIXTURES = File.expand_path("../fixtures", __dir__)

  # Enough of a Net::HTTPResponse for Exchange.from_http to record one.
  Answer = Struct.new(:code, :body, :headers, keyword_init: true) do
    def each_header = (headers || {}).each
  end

  # Hands back the queued answers in order, so a POST-then-GET discovery is one script.
  # `retry_untils` are what each send was told about when its retrying stops.
  class Transport
    attr_reader :paths, :retry_untils

    def initialize(answers)
      @answers = Array(answers)
      @paths = []
      @retry_untils = []
    end

    def perform(path:, retry_until: nil)
      @paths << path
      @retry_untils << retry_until
      raise "no canned answer left for #{path}" if @answers.empty?

      @answers.shift
    end
  end

  def canned(fixture, status: 200, headers: {})
    Answer.new(code: status.to_s, headers: headers,
               body: File.read(File.join(FIXTURES, "#{fixture}.json")))
  end

  # A fixture changed for one example.
  def canned_body(json, status: 200)
    Answer.new(code: status.to_s, headers: {}, body: JSON.generate(json))
  end

  # `archive:` defaults to nothing rather than to what the environment configures, so a machine
  # with EDI_ARCHIVE_TEMPLATE set in its shell profile does not quietly give every spec in this suite
  # a real archive writing real files.
  # `options` go to Stedi.new as given (payer_pauses, sleeper, clock).
  def stedi_answering(*answers, archive: nil, **options)
    transport = Transport.new(answers)
    [EdiGem::Source::Stedi.new(api_key: "test_key", transport: transport, archive: archive, **options),
     transport]
  end

  # A raw body rather than a fixture file, for the X12 sources -- their answers are X12 and
  # SOAP, not JSON, and several of them are three lines long.
  def answering(body, status: 200, headers: {})
    Answer.new(code: status.to_s, headers: headers, body: body)
  end

  # The five values Office Ally and Optum each assign at enrolment, plus the endpoint that
  # arrives with the signed agreement. Nothing here is real; they are the shape, not the values.
  def enrolled(source, **overrides)
    EdiGem::Credential.new(
      provider: nil, source: source, enrolled_at: Time.now,
      values: { sender_id: "EXAMPLECLINIC", receiver_id: "OFFALLY",
                application_sender: "987654321", application_receiver: "OFFALLY",
                endpoint: "https://example.invalid/rte", control_number: "1" }.merge(overrides)
    )
  end

  def x12_answering(klass, *answers, **credential)
    transport = Transport.new(answers)
    source = klass.new(credential: enrolled(klass::NAME, **credential), transport: transport,
                       now: Time.new(2026, 9, 4, 13, 45, 0))
    [source, transport]
  end
end
