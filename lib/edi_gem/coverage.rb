# frozen_string_literal: true

module EdiGem
  # Whether a person is covered by a plan on a day, by Stedi's two-part test: the day falls within
  # the plan's eligibility period (a line's own dates win for that line), and a line about the
  # plan as a whole (service type 30) says the person is covered. One rule for an eligibility
  # check and for each coverage a discovery found.
  #
  #   EdiGem::Coverage.on(response.benefits, Date.current)  # => #<Finding status=:active code="1">
  module Coverage
    PLAN = "30"

    # A plan term on 30 (a co-payment, a deductible, a limitation) implies the person is covered.
    # These don't: they describe what surrounds the coverage (another payer, whom to contact, a
    # lost card, where the data came from, a disclaimer), not the coverage itself.
    NOT_IMPLYING = %i[other_payer contact_entity card_lost_or_stolen other_data_source
                      benefit_disclaimer].freeze

    # `status` is :active, :inactive, :non_covered, :cannot_process, or nil when no line on 30
    # decides. `code` is the EB01 status code of the line that decided (1 to 8, I, V); nil when
    # the plan's dates or an implied term decided.
    Finding = Struct.new(:status, :code, keyword_init: true) do
      def active? = status == :active
    end

    UNDECIDED = Finding.new(status: nil, code: nil).freeze
    OUTSIDE_DATES = Finding.new(status: :inactive, code: nil).freeze

    module_function

    # Explicit statuses first, active over inactive; then an implied term; then the payer's own
    # refusals. Lines on 30 that the day falls outside of make the plan inactive only when no line
    # within its dates decides.
    def on(benefits, date)
      day = date.respond_to?(:strftime) ? date.strftime("%Y%m%d") : date.to_s
      lines = benefits.select { |benefit| benefit.line? && about_plan?(benefit) }
      current, outside = lines.partition { |benefit| within?(benefit, day) }
      decide(current) || (outside.any? ? OUTSIDE_DATES : UNDECIDED)
    end

    # A line that names no service type is about the plan as a whole.
    def about_plan?(benefit)
      types = benefit.service_types
      types.nil? || types.empty? || types.include?(PLAN)
    end

    def within?(benefit, day)
      begins = benefit.line_begins_on || benefit.begins_on
      ends = benefit.line_ends_on || benefit.coverage_ends_on || benefit.ends_on
      (begins.nil? || day >= begins) && (ends.nil? || day <= ends)
    end

    def decide(lines)
      %i[active inactive].each do |status|
        decided = with_status(lines, status)
        return decided if decided
      end
      return Finding.new(status: :active, code: nil) if lines.any? { |line| implies_coverage?(line) }

      with_status(lines, :non_covered) || with_status(lines, :cannot_process)
    end

    # The lowest code wins among lines of one status, so a plain active (1) is the one named
    # rather than active pending investigation (5) when the payer sends both.
    def with_status(lines, status)
      line = lines.select { |candidate| candidate.status == status }.min_by { |candidate| candidate.status_code.to_s }
      Finding.new(status: status, code: line.status_code) if line
    end

    def implies_coverage?(line)
      !line.benefit_type.nil? && !NOT_IMPLYING.include?(line.benefit_type)
    end
  end
end
