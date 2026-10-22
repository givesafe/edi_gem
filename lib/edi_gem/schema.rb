# frozen_string_literal: true

module EdiGem
  # The map from one source's response fields to the shared vocabulary, declared as data: where
  # benefits, rejections and details live, and which field fills each name.
  #
  #   Schema.define(:stedi) do
  #     benefit "benefitsInformation[]" do
  #       field :status, from: "code", codec: :eb01_status
  #     end
  #     rejection "subscriber.aaaErrors[]", level: :subscriber do
  #       field :code, from: "code", codec: :aaa03
  #     end
  #   end
  class Schema
    class << self
      def define(name, &block)
        registry[name.to_sym] = new(name).tap { |schema| schema.instance_eval(&block) }
      end

      def fetch(name)
        registry.fetch(name.to_sym) { raise UnknownSchema, "no schema registered for #{name}" }
      end

      def registry
        @registry ||= {}
      end
    end

    # One block of a schema: where in the document to look, which lane anything found belongs to,
    # and which fields to read out of each record there.
    Mapping = Struct.new(:address, :level, :fields, :fallback, keyword_init: true) do
      # A fallback address (a flattened error list) is read only for what the lanes lack.
      def fallback? = fallback
    end
    # One field: its name, its path in the vendor's record, and an optional codec.
    Field = Struct.new(:name, :from, :codec, keyword_init: true)

    attr_reader :name, :benefits, :rejections, :details, :people, :found_plans

    def initialize(name)
      @name = name.to_sym
      @benefits = []
      @rejections = []
      @details = []
      @people = []
      @found_plans = []
    end

    def benefit(address, &block)
      @benefits << build(address, nil, block)
    end

    # Facts about the exchange rather than the coverage (mode, trace id). One flat set; the
    # default address is the whole document.
    def detail(address = "", &block)
      @details << build(address, nil, block)
    end

    def rejection(address, level:, fallback: false, &block)
      @rejections << build(address, level, block, fallback: fallback)
    end

    # The people the answer names: the subscriber, and any dependents. `role` is :subscriber or
    # :dependent; the fields are Person's.
    def person(address, role:, &block)
      @people << build(address, role, block)
    end

    # Where each record is one whole coverage a discovery found (Reading#found_plans). The
    # benefits and people under it are read by their own blocks.
    def found_plan(address)
      @found_plans << address
    end

    private

    def build(address, level, block, fallback: false)
      fields = []
      collector = FieldCollector.new(fields)
      collector.instance_eval(&block)
      Mapping.new(address: address, level: level, fields: fields, fallback: fallback)
    end

    # Collects `field` declarations without exposing the rest of the schema to the block.
    class FieldCollector
      def initialize(fields)
        @fields = fields
      end

      def field(name, from:, codec: nil)
        @fields << Field.new(name: name.to_sym, from: from, codec: codec)
      end
    end
  end
end
