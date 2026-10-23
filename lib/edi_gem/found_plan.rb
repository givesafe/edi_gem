# frozen_string_literal: true

module EdiGem
  # One coverage an insurance discovery found: its payer, its benefit lines, and the people on it.
  # A discovery can find several, each at its own payer and about its own people, so each is read
  # apart and nothing of one reaches another.
  #
  # Discovery matches on demographics and can return false positives, so `person` is who the payer
  # matched, as it holds them on record (name, birth date, address), for the caller to confirm.
  class FoundPlan
    include Concealed

    attr_reader :benefits, :people

    def initialize(benefits:, people:)
      @benefits = benefits
      @people = people
    end

    # A field of the plan as a whole (payer_code, member_id, state_insurance_id, plan_name, ...):
    # the first of its benefit lines that holds it.
    def [](field)
      @benefits.each do |benefit|
        value = benefit[field]
        return value unless value.nil?
      end
      nil
    end

    def payer_code = self[:payer_code]
    def member_id = self[:member_id]

    # X12 service type codes for dental (23-28, 35-41) and vision (AL-AO).
    DENTAL_OR_VISION_SERVICE_TYPES = (%w[23 24 25 26 27 28] + ("35".."41").to_a + %w[AL AM AN AO]).freeze

    # Whether the plan covers medical care: a line names a service type other than dental or
    # vision. Lines that name no service type say nothing either way, so a plan of only those is
    # medical.
    def medical?
      service_types = @benefits.flat_map { |benefit| Array(benefit.service_types) }
      service_types.empty? || (service_types - DENTAL_OR_VISION_SERVICE_TYPES).any?
    end

    # Whether this plan names `other`'s payer as its primary payer, as an MCO's plan names the
    # state Medicaid plan it manages.
    def names_as_primary_payer?(other)
      code = self[:primary_payer_code]
      !code.to_s.strip.empty? && code == other.payer_code
    end

    def subscriber_person
      @people.find { |person| !person.dependent? }
    end

    def dependent_people
      @people.select(&:dependent?)
    end

    # When the patient is a dependent, Stedi puts them in `dependent` and the policyholder in
    # `subscriber`, so the dependent is the person matched.
    def person
      dependent_people.first || subscriber_person
    end

    # How the person matched compares with who was asked about (Identity.compare's options).
    def identify(asked, **options)
      Response::Identification.of(person, asked, **options)
    end

    # Whether the plan covers the person on this day (Coverage's two-part test).
    def coverage_on(date)
      Coverage.on(@benefits, date)
    end

    def concealed_inspect
      "#<#{self.class} benefits=#{@benefits.size} people=#{@people.map(&:role).join(",")}>"
    end
  end
end
