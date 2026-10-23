# frozen_string_literal: true

module EdiGem
  module Source
    class Stedi < Base
      # Stedi's payer directory. A search is not a billed transaction.
      module Directory
        PAGE_SIZE = 100
        # Whose payer IDs payer_id_for gives: Stedi's, for the mock too, which asks Stedi's directory.
        NAME = :stedi

        def directory_name = NAME

        # The payers the directory returns for one term, best match first. Which of them are the
        # payer asked for is for the caller to decide.
        def payers(term)
          exchange = get(:payer_search, @policy.path_for(:payer_search),
                         query: { query: term, pageSize: PAGE_SIZE })
          parse(exchange).fetch("items", []).map { |item| ListedPayer.from_stedi(item.fetch("payer")) }
        end

        # Stedi's payer ID for a code or alias from any answer, or nil when the directory holds no
        # single payer that answers to it. Exact only: a name is never matched, the payer whose
        # own code it is wins, and a code that more than one payer answers to by alias resolves
        # to none.
        #
        # One search per code for the source's lifetime: the answer, nil included, is remembered.
        # A failed search raises (Fault, UnreadableBody) and is not remembered.
        def payer_id_for(payer_code)
          return if EdiGem.blank?(payer_code)

          code = payer_code.to_s
          @payer_ids ||= {}
          return @payer_ids[code] if @payer_ids.key?(code)

          @payer_ids[code] = listed_payer_id(code)
        end

        private

        # Chooses among the payers that answer to a code.
        # :reek:FeatureEnvy
        def listed_payer_id(code)
          answering = payers(code).select { |payer| payer.answers_to?(code) }
          found = answering.find { |payer| payer.code?(code) } || (answering.first if answering.one?)
          found&.code
        end
      end
    end
  end
end
