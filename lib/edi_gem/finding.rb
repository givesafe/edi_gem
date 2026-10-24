# frozen_string_literal: true

module EdiGem
  # What an answer established about the person asked about, asked as they were asked: one name, and
  # the code behind it. It is the meaning only. What to do with it is the caller's, and depends on
  # the moment (a check with the person there, a recheck without them, a discovery).
  #
  #   covered           an active line (EB01 1-5) covers the person on the day
  #   not_covered       an inactive line (6-8), not covered (I), the day outside the plan's dates, or an
  #                     answer with no lines: not covered on this plan. They may have another
  #   someone_else      the answer is about a person who isn't the one asked (our name and birth date
  #                     comparison): the ID is real and someone's, and says nothing of our person
  #   held_differently  the payer found the ID but holds the person under another birth date
  #                     (AAA 71, 58) or name (73, 65). Not certainly someone else
  #   not_on_this_id    the person isn't on the payer's books under this ID: the ID invalid (72, 64),
  #                     not found (75, 67, 77) or more than one match (76, 68). Not a denial
  #   provider_refused  the payer won't answer our provider. Nothing about the person
  #   no_answer         the payer was silent, couldn't process (V), or no line decides
  #   our_fault         our request was refused at the transport or envelope: we didn't ask properly
  #   pending           an asynchronous answer that hasn't arrived
  #
  # A finding a plan's own line decided keeps that line (#line_code, #inactive?), so a caller that
  # records one word can tell a plan that ended from one never covered.
  class Finding
    NAMES = %i[covered not_covered someone_else held_differently not_on_this_id provider_refused
               no_answer our_fault pending].freeze

    # What a plan's own lines say (Coverage::Finding#status); cannot_process or no line is no answer.
    BY_COVERAGE = { active: :covered, inactive: :not_covered, non_covered: :not_covered }.freeze

    # The refusals about the person (Codec::REJECT_REASON names) that say the payer holds them
    # differently; the rest of Response::State::NOT_IDENTIFIED_CODES say they aren't on this ID.
    HELD_DIFFERENTLY = %i[date_of_birth_mismatch name_mismatch].freeze

    attr_reader :name, :code

    # A plan's coverage on the day (a Coverage::Finding), as a discovery reads each plan it found:
    # always about the person the plan names, whoever was asked.
    def self.of_coverage(coverage)
      new(BY_COVERAGE.fetch(coverage.status, :no_answer), code: coverage.code, line: coverage)
    end

    # A discovery's answer among `plans`, its medical plans, each read on the day: the best any plan
    # found, where a plan neither covered nor inactive is no denial. With no plan, the state decides,
    # and an answer that names none found none.
    def self.of_discovery(response, plans, on:)
      found = plans.map { |plan| plan.finding(on: on) }
      return of_search(response) if found.empty?

      found.find(&:covered?) || found.find(&:inactive?) || new(:no_answer)
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

    # A discovery's answer that found no plan, by its state.
    def self.of_search(response)
      case response.state
      when :pending then new(:pending)
      when :rejected then refused(response)
      when :payer_silent then silent(response)
      else new(:not_covered)
      end
    end

    # A source can give the state with no refusal behind it.
    def self.silent(response) = new(:no_answer, code: response.rejections.first&.code)

    def self.refused(response)
      refusal = response.provider_refusals.first
      return new(:provider_refused, code: refusal.code) if refusal

      new(:our_fault, code: response.rejections.first&.code)
    end

    def self.not_identified(response)
      code = %i[subscriber dependent].flat_map { |level| response.rejections_at(level) }.map(&:code)
                                     .find { |one| Response::State::NOT_IDENTIFIED_CODES.include?(one) }
      new(HELD_DIFFERENTLY.include?(code) ? :held_differently : :not_on_this_id, code: code)
    end

    def self.answered(response, identification, day)
      return new(:someone_else) if identification.mismatched?
      return new(:not_covered) if response.state == :no_coverage

      of_coverage(response.coverage_on(day))
    end

    private_class_method :of_search, :silent, :refused, :not_identified, :answered

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

    # The EB01 status code of the line that decided, to record beside the finding; nil when no line
    # did (the state, a refusal or the person decided), or the plan's dates or an implied term did.
    def line_code = @line&.code

    def to_s = @name.to_s

    def inspect = "#<#{self.class} #{@name}#{" code=#{@code}" if @code}>"
  end
end
