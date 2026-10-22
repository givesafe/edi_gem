# frozen_string_literal: true

module EdiGem
  # Applies a Schema to a Document. The one implementation of reading a response; a new source
  # contributes a schema, not code here.
  class Reading
    def initialize(document:, schema:)
      @document = document
      @schema = schema
    end

    # One Benefit per benefit line. Each schema block reads a fragment (payer, subscriber, plan,
    # line); fragments are reassembled by position, and a fragment whose position another one
    # extends is folded into that deeper one.
    def benefits
      fragments = @schema.benefits.flat_map { |mapping| placed(mapping) }
      leaves(fragments).map { |at| Benefit.new(assembled(fragments, at)) }
    end

    # Lane addresses first, then only what a fallback (flattened) list adds beyond them, so no
    # refusal is counted twice or moved to the wrong lane.
    def rejections
      lanes, fallbacks = @schema.rejections.partition { |mapping| !mapping.fallback? }
      found = lanes.flat_map { |mapping| for_lane(mapping) }
      found + fallbacks.flat_map { |mapping| for_lane(mapping) }
                       .reject { |rejection| found.any? { |kept| kept.same_refusal_as?(rejection) } }
    end

    # One Person per role and position: an X12 person is spread over NM1, DMG and INS at one
    # level, so the fragments one role finds at one position are one person. Subscriber first.
    def people
      person_fragments.group_by(&:first)
                      .filter_map { |(role, _), fragments| person(role, fragments.map(&:last)) }
                      .sort_by { |found| found.dependent? ? 1 : 0 }
    end

    def details
      @schema.details.each_with_object({}) do |mapping, found|
        @document.records(mapping.address)
                 .each { |record| found.merge!(attributes(mapping, record)) }
      end
    end

    private

    def person_fragments
      @schema.people.flat_map do |mapping|
        placed(mapping).map { |at, attributes| [[mapping.level, at], attributes] }
      end
    end

    # The earlier fragment wins a field two carry. nil when none held a field.
    def person(role, fragments)
      attributes = fragments.reduce({}) { |all, one| one.merge(all) }
      Person.new(role: role, **attributes) unless attributes.empty?
    end

    def placed(mapping)
      @document.locate(mapping.address).map { |at, record| [at, attributes(mapping, record)] }
    end

    # The deepest positions, one per Benefit.
    def leaves(fragments)
      found = fragments.map(&:first).uniq
      found.reject do |one|
        found.any? { |other| other.length > one.length && other.first(one.length) == one }
      end
    end

    # Everything at this position or above it, shallowest first, so the deeper fragment wins a
    # field both carry.
    def assembled(fragments, at)
      fragments.select { |place, _| at.first(place.length) == place }
               .group_by { |place, _| place.length }.sort.flat_map(&:last)
               .reduce({}) { |found, (_, attributes)| found.merge(attributes) }
    end

    # A fallback entry takes its level from the loop it names, else the mapping's level.
    def for_lane(mapping)
      build(mapping) do |attrs|
        level = mapping.fallback? && Rejection.level_from(attrs[:location])
        Rejection.new(**attrs, level: level || mapping.level)
      end
    end

    def build(mapping)
      @document.records(mapping.address).map { |record| yield(attributes(mapping, record)) }
    end

    # Empty values are dropped (X12 pads absent elements). A field declared twice takes the
    # first declaration that holds a value.
    def attributes(mapping, record)
      mapping.fields.each_with_object({}) do |field, found|
        next if found.key?(field.name)

        value = Codec.decode(field.codec, record.value(field.from))
        found[field.name] = value unless value.nil? || value == ""
      end
    end
  end
end
