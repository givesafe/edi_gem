# frozen_string_literal: true

module EdiGem
  # Whether the person a payer answered about is the person asked about, field by field.
  #
  # Payers spell names their own way: some uppercase, drop accents, hyphens and suffixes, or cut a
  # long name short, and only CORE-certified payers follow CAQH CORE 258's normalization. So names
  # are compared after normalizing both sides, and a few spellings of the same name pass. A name
  # that is another name (Leo and Leon, Aiden and Jaden), a nickname, or first and last swapped
  # does not: a one-letter difference is how twins and siblings differ. The birth date must be
  # exact.
  module Identity
    # CORE 258's suffixes and titles, dropped from a last name before comparing.
    SUFFIXES = %w[JR SR I II III IV V RN MD MR MS DR MRS PHD REV ESQ].freeze

    # The shortest name a payer is taken to have cut short. Below it, a prefix is too likely to be
    # another name (LEO is the start of LEONARD).
    TRUNCATED_AT = 8

    FIELDS = %i[first_name last_name date_of_birth].freeze
    NAME_RULES = { first_name: :same_first?, last_name: :same_last? }.freeze

    # Characters with no decomposed form, spelled as payers write them.
    LETTERS = { "ß" => "SS", "Æ" => "AE", "æ" => "AE", "Œ" => "OE", "œ" => "OE", "Ø" => "O",
                "ø" => "O", "Ł" => "L", "ł" => "L", "Đ" => "D", "đ" => "D", "Þ" => "TH",
                "þ" => "TH" }.freeze
    MARKS = /\p{Mn}/
    LETTER = Regexp.union(LETTERS.keys)

    # One field's result: matched, differs, or not_returned (the payer sent nothing to compare).
    # `corrected` names the fields that passed only because the payer said it corrected them.
    Result = Struct.new(:fields, :corrected, keyword_init: true) do
      # matched when every field matched; mismatched when any differs; not_compared otherwise.
      def outcome
        return :mismatched if fields.value?(:differs)
        return :matched if fields.values.all?(:matched)

        :not_compared
      end

      def matched? = outcome == :matched

      def mismatched? = outcome == :mismatched

      def differing = fields.select { |_, result| result == :differs }.keys
    end

    module_function

    # A name as sent to a payer: accents spelled out, uppercase, spaces squeezed. Punctuation is
    # kept, since a payer may hold GARCIA-LOPEZ or O'BRIEN as written. nil stays nil.
    def plain(name)
      return nil if name.nil?

      name.to_s.gsub(LETTER, LETTERS).unicode_normalize(:nfkd).gsub(MARKS, "")
          .upcase.gsub("`", "'").squeeze(" ").strip
    end

    # The words of a name, for comparing: plain, with every other character a space.
    def words(name)
      plain(name).to_s.gsub(/[^A-Z0-9]+/, " ").split
    end

    # A last name's words without suffixes and titles, unless that would leave none.
    def surname_words(name)
      found = words(name)
      kept = found.reject { |word| SUFFIXES.include?(word) }
      kept.empty? ? found : kept
    end

    # `asked` and `returned` are hashes of first_name, last_name and date_of_birth (a Date or
    # YYYYMMDD; hyphens are ignored). `corrected` is the payer's 001/25: it says it changed the
    # identifying information it matched on, so names count as matched when the birth date does.
    # `truncated` allows the returned name to be the asked one cut short; compare two names we
    # hold with it off.
    def compare(asked:, returned:, corrected: false, truncated: true, truncated_at: TRUNCATED_AT)
      cut = (truncated_at if truncated)
      fields = NAME_RULES.to_h do |name, rule|
        [name, field(asked[name], returned[name]) { |one, other| send(rule, one, other, cut) }]
      end
      born = field(day(asked[:date_of_birth]), day(returned[:date_of_birth])) { |one, other| one == other }
      relax(fields.merge(date_of_birth: born), corrected)
    end

    def relax(fields, corrected)
      names = %i[first_name last_name].select { |name| fields[name] == :differs }
      return Result.new(fields: fields, corrected: []) unless corrected && names.any? &&
                                                              fields[:date_of_birth] == :matched

      Result.new(fields: fields.merge(names.to_h { [_1, :matched] }), corrected: names)
    end

    # Nothing asked counts as nothing to compare, like nothing returned.
    def field(asked, returned)
      return :not_returned if blank?(asked) || blank?(returned)

      yield(asked, returned) ? :matched : :differs
    end

    # `cut` is the shortest name taken as cut short, or nil when cutting short is not allowed.
    def same_first?(asked, returned, cut)
      one = words(asked)
      other = words(returned)
      return false if one.empty? || other.empty?

      one.join == other.join || first_of?(one, other) ||
        (cut && cut_short?(one.join(" "), other.join(" "), cut))
    end

    # One name is the other's first word: MARY for MARY ANN.
    def first_of?(one, other)
      one.first == other.first && (one.one? || other.one?)
    end

    def same_last?(asked, returned, cut)
      one = surname_words(asked)
      other = surname_words(returned)
      return false if one.empty? || other.empty?

      one.join == other.join || (one - other).empty? || (other - one).empty? ||
        (cut && cut_short?(one.join, other.join, cut))
    end

    # Whether the returned name is the asked one cut short, at a length a payer cuts to.
    def cut_short?(asked, returned, truncated_at)
      returned.length >= truncated_at && returned.length < asked.length &&
        asked.start_with?(returned)
    end

    def day(value)
      return nil if blank?(value)

      value.respond_to?(:strftime) ? value.strftime("%Y%m%d") : value.to_s.delete("-").strip
    end

    def blank?(value) = value.nil? || value.to_s.strip.empty?
  end
end
