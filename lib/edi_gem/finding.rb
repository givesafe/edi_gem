# frozen_string_literal: true

module EdiGem
  # What an answer established about the person asked about, asked as they were asked: one name, and
  # the code behind it. It is the meaning only. What to do with it is the caller's, and depends on
  # the moment (a check with the person there, a recheck without them, a discovery).
  #
  #   covered           an active line (EB01 1-5) covers the person on the day
  #   not_covered       an inactive line (6-8), not covered (I), the day outside the plan's dates, or the
  #                     person's date of death before the day: not covered on this plan. They may have another
  #   someone_else      the answer is about a person who isn't the one asked (our name and birth date
  #                     comparison): the ID is real and someone's, and says nothing of our person
  #   held_differently  the payer found the ID but holds the person under another birth date or name.
  #                     Not certainly someone else
  #   not_on_this_id    the person isn't on the payer's books under this ID. Not a denial
  #   provider_refused  the payer won't answer our provider. Nothing about the person
  #   no_answer         the payer was silent, couldn't process (V), sent no lines, or no line decides
  #   nothing_found     a discovery found no plan, which says nothing of whether the person is covered
  #   our_fault         our request was refused at the transport or envelope, or for what we sent in
  #                     it: we didn't ask properly
  #
  # Which refusal codes mean which is PersonRefusal::FINDINGS.
  #   pending           an asynchronous answer that hasn't arrived
  #
  # A finding a plan's own line decided keeps that line (#inactive?), so a caller that
  # records one word can tell a plan that ended from one never covered.
  class Finding
    NAMES = %i[covered not_covered someone_else held_differently not_on_this_id provider_refused
               no_answer nothing_found our_fault pending].freeze

    # What a plan's own lines say (Coverage::Finding#status); cannot_process or no line is no answer.
    BY_COVERAGE = { active: :covered, inactive: :not_covered, non_covered: :not_covered }.freeze

    attr_reader :name, :code

    # A plan's coverage on the day (a Coverage::Finding), as a discovery reads each plan it found:
    # always about the person the plan names, whoever was asked.
    def self.of_coverage(coverage)
      new(BY_COVERAGE.fetch(coverage.status, :no_answer), code: coverage.code, line: coverage)
    end

    # A check's answer (`response`) about the person `identification` names, on the day.
    def self.of_check(response, identification, on:)
      case response.state
      when :pending then new(:pending)
      when :rejected then refused(response)
      when :not_identified then not_identified(response)
      when :payer_silent then silent(response)
      else answered(response, identification, on)
      end
    end

    # A discovery's answer that found no plan, by its state: an answer that names none found none.
    # Which of the plans it found decide is the caller's, so a discovery with plans reads each one
    # (FoundPlan#finding).
    def self.of_search(response)
      case response.state
      when :pending then new(:pending)
      when :rejected then refused(response)
      when :payer_silent then silent(response)
      else new(:nothing_found)
      end
    end

    # A source can give the state with no refusal behind it.
    def self.silent(response) = new(:no_answer, code: response.rejections.first&.code)

    def self.refused(response)
      refusal = response.provider_refusals.first
      return new(:provider_refused, code: refusal.code) if refusal

      rejections = response.rejections
      new(:our_fault, code: PersonRefusal.finding_among(rejections)&.last || rejections.first&.code)
    end

    def self.not_identified(response)
      name, code = PersonRefusal.finding_among(response.rejections)
      new(name, code: code)
    end

    def self.answered(response, identification, day)
      return new(:someone_else) if identification.mismatched?
      return person_not_covered(response) if response.state == :no_coverage

      of_coverage(response.coverage_on(day))
    end

    def self.person_not_covered(response)
      name, code = PersonRefusal.finding_among(response.rejections)
      new(name || :no_answer, code: code)
    end

    private_class_method :silent, :refused, :not_identified, :answered, :person_not_covered

    # `code` is the EB01 status code of the line that decided, the refusal's reason (a
    # Codec::REJECT_REASON name, or the raw code the codec didn't name), or nil. `line` is the plan's
    # coverage on the day (a Coverage::Finding) when it decided; nil when the state or the person did.
    def initialize(name, code: nil, line: nil)
      raise ArgumentError, "unknown finding #{name}" unless NAMES.include?(name)

      @name = name
      @code = code
      @line = line
    end

    NAMES.each { |one| define_method(:"#{one}?") { @name == one } }

    # Whether the plan's own lines say it is inactive on the day (EB01 6 to 8, or the day outside the
    # plan's dates): not covered as one who was and no longer is, rather than never covered (I) or no
    # lines at all.
    def inactive? = @line&.inactive? || false

    def to_s = @name.to_s

    def inspect = "#<#{self.class} #{@name}#{" code=#{@code}" if @code}>"
  end
end
