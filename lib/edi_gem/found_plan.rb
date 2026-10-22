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
