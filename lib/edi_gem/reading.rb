# frozen_string_literal: true

module EdiGem
  # Applies a Schema to a Document. The one implementation of reading a response; a new source
  # contributes a schema, not code here.
  class Reading
    def initialize(document:, schema:)
      @document = document
      @schema = schema
    end

    # Everything the schema reads, as Response takes it.
    def parts
      { benefits: benefits, rejections: rejections, people: people, found_plans: found_plans, details: details }
    end

    # One Benefit per benefit line. Each schema block reads a fragment (payer, subscriber, plan,
    # line); fragments are reassembled by position, and a fragment whose position another one
    # extends is folded into that deeper one.
    def benefits
      placed_benefits.map(&:last)
    end

    # Lane addresses first, then only what a fallback (flattened) list adds beyond them, so no
    # refusal is counted twice or moved to the wrong lane. A found plan's own refusals are that
    # plan's, not the answer's.
    def rejections
      found = placed_rejections.map(&:last)
      answers = placed_rejections.filter_map { |at, rejection| rejection unless in_a_plan?(at) }
      answers + fallback_rejections.reject { |rejection| found.any? { |kept| kept.same_refusal_as?(rejection) } }
    end

    # One Person per role and position: an X12 person is spread over NM1, DMG and INS at one
    # level, so the fragments one role finds at one position are one person. Subscriber first.
    def people
      people_from(person_fragments.reject { |(_, at), _| in_a_plan?(at) })
    end

    # One FoundPlan per coverage a discovery found, with only the benefits and people under it.
    def found_plans
      plan_positions.map do |plan|
        FoundPlan.new(benefits: placed_benefits.filter_map { |at, benefit| benefit if under?(at, plan) },
                      people: people_from(person_fragments.select { |(_, at), _| under?(at, plan) }),
                      rejections: placed_rejections.filter_map { |at, rejection| rejection if under?(at, plan) })
      end
    end

    def details
      @schema.details.each_with_object({}) do |mapping, found|
        @document.records(mapping.address)
                 .each { |record| found.merge!(attributes(mapping, record)) }
      end
    end

    private

    def placed_benefits
      @placed_benefits ||= begin
        fragments = @schema.benefits.flat_map { |mapping| placed(mapping) }
        leaves(fragments).map { |at| [at, Benefit.new(assembled(fragments, at))] }
      end
    end

    def plan_positions
      @plan_positions ||= @schema.found_plans.flat_map { |address| @document.locate(address).map(&:first) }
    end

    def under?(at, place) = at.first(place.length) == place

    def in_a_plan?(at) = plan_positions.any? { |plan| under?(at, plan) }

    def placed_rejections
      @placed_rejections ||= @schema.rejections.reject(&:fallback?).flat_map do |mapping|
        placed(mapping).map { |at, attributes| [at, Rejection.new(**attributes, level: mapping.level)] }
      end
    end

    def fallback_rejections
      @schema.rejections.select(&:fallback?).flat_map do |mapping|
        build(mapping) do |attrs|
          Rejection.new(**attrs, level: Rejection.level_from(attrs[:location]) || mapping.level)
        end
      end
    end

    def people_from(fragments)
      fragments.group_by(&:first)
               .filter_map { |(role, _), found| person(role, found.map(&:last)) }
               .sort_by { |found| found.dependent? ? 1 : 0 }
    end

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
      fragments.select { |place, _| under?(at, place) }
               .group_by { |place, _| place.length }.sort.flat_map(&:last)
               .reduce({}) { |found, (_, attributes)| found.merge(attributes) }
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
