# frozen_string_literal: true

# EdiGem.reveal, and the Concealed mixin it switches.
module EdiGem
  class << self
    # Whether objects holding secrets or PHI print them in full. Off unless set to true, so a
    # production that never sets it prints nothing it shouldn't. Turn it on only where there is
    # no real member data and no production key (local, staging), to see what a call carried.
    def reveal? = @reveal == true

    def reveal=(value)
      @reveal = value == true
    end
  end

  # Included by every object that holds a secret (an API key, an AWS secret, a portal password)
  # or PHI (names, dates of birth, member ids, request and response bodies). Its inspect prints
  # only the class's `concealed_inspect` (field names, sizes, states), never a value, because
  # inspect output ends up in exceptions, log lines and consoles. With EdiGem.reveal on it prints
  # the object as Ruby would, and the objects inside it print in full too.
  module Concealed
    def inspect
      EdiGem.reveal? ? super : concealed_inspect
    end

    # What pp and a console print. Revealed, it lays out every instance variable as pp would.
    def pretty_print(printer)
      EdiGem.reveal? ? printer.pp_object(self) : printer.text(concealed_inspect)
    end

    private

    def concealed_inspect = "#<#{self.class}>"
  end
end
