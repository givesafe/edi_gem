# frozen_string_literal: true

module EdiGem
  # The forms of a person's name the gem and its callers share: as every request sends it to a
  # payer, as its words, and as it says who someone is. Payers spell names their own way (some
  # uppercase, drop accents, hyphens and suffixes, or cut a long name short), and only
  # CORE-certified payers follow CAQH CORE 258's normalization, so a caller that compares a payer's
  # spelling with its own starts from these forms. How two names compare is the caller's.
  module Identity
    # Generation suffixes. Stedi takes one in its own suffix field rather than in the last name, and
    # one says who someone is: a JR is another person than his father.
    SUFFIXES = %w[JR SR I II III IV V].freeze
    # Titles and degrees. They are not sent, and they don't count when comparing.
    TITLES = %w[RN MD MR MS DR MRS PHD REV ESQ].freeze
    # The characters Stedi refuses in a request, removed from every name sent.
    UNSENDABLE = /[~*:^>]/
    # Whether a word is a title, written with or without its period or comma.
    TITLE = ->(word) { TITLES.include?(bare(word)) }

    # The shortest name a payer is taken to have cut short. Below it, a prefix is too likely to be
    # another name (LEO is the start of LEONARD).
    TRUNCATED_AT = 8

    # The fields that say who a person is.
    FIELDS = %i[first_name last_name date_of_birth].freeze

    # Characters with no decomposed form, spelled as payers write them.
    LETTERS = { "ß" => "SS", "Æ" => "AE", "æ" => "AE", "Œ" => "OE", "œ" => "OE", "Ø" => "O",
                "ø" => "O", "Ł" => "L", "ł" => "L", "Đ" => "D", "đ" => "D", "Þ" => "TH",
                "þ" => "TH" }.freeze
    MARKS = /\p{Mn}/
    LETTER = Regexp.union(LETTERS.keys)

    module_function

    # A name as every request spells it for a payer: accents removed (é is E, ß is SS), uppercase,
    # the characters Stedi refuses removed, spaces squeezed. Other punctuation is kept, since a payer
    # may hold GARCIA-LOPEZ or O'BRIEN as written. nil stays nil.
    def payer_normalized(name)
      return nil if name.nil?

      name.to_s.gsub(LETTER, LETTERS).unicode_normalize(:nfkd).gsub(MARKS, "")
          .upcase.gsub("`", "'").gsub(UNSENDABLE, "").squeeze(" ").strip
    end

    # A first or middle name as it is sent: payer_normalized without a title at either end.
    def payer_sent(name)
      untitled(payer_normalized(name))&.join(" ")
    end

    # A last name as it is sent, and its suffix apart: "Smith Jr." is ["SMITH", "JR"],
    # "Smith" is ["SMITH", nil]. Titles are not sent. A one-word name is never a suffix (V stays V).
    def payer_sent_last_name(name)
      words = untitled(payer_normalized(name))
      return [nil, nil] if words.nil?

      *rest, last = words
      suffix = bare(last)
      return [words.join(" "), nil] if rest.empty? || !SUFFIXES.include?(suffix)

      [rest.join(" ").chomp(","), suffix]
    end

    # A last name's suffix (JR, SR, I, II, III, IV, V), or nil when it has none.
    def suffix(name)
      payer_sent_last_name(name).last
    end

    # The words of a name, for comparing: payer_normalized, with every other character a space.
    def payer_normalized_split(name)
      payer_normalized(name).to_s.gsub(/[^A-Z0-9]+/, " ").split
    end

    # A name as it says who someone is: its words run together, so accents, case, spaces, hyphens and
    # apostrophes don't count and suffixes do (a JR is another person). Two people we hold are one
    # when their db_normalized names and birth dates are. nil for a blank name.
    def db_normalized(name)
      joined = payer_normalized_split(name).join
      joined unless joined.empty?
    end

    # A last name's words without suffixes and titles, unless that would leave none.
    # Whether two last names differ by a suffix is .suffix's to say.
    def surname_words(name)
      found = payer_normalized_split(name)
      kept = found.reject { |word| SUFFIXES.include?(word) || TITLES.include?(word) }
      kept.empty? ? found : kept
    end

    # A name's words without a title at either end, unless that would leave none. nil stays nil.
    def untitled(normalized)
      return nil if normalized.nil?

      words = normalized.split
      kept = words.drop_while(&TITLE).reverse.drop_while(&TITLE).reverse
      kept.empty? ? words : kept
    end

    # A word without the periods and commas around an abbreviation (JR. and DR, are JR and DR).
    def bare(word) = word.delete(".,")

    private_class_method :untitled, :bare
  end
end
