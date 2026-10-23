# frozen_string_literal: true

# The gem's namespace: one API for healthcare eligibility across clearinghouses.
module EdiGem
  # Text that says nothing: empty, or only spaces.
  BLANK = /\A[[:space:]]*\z/

  # nil, or a value whose text is blank. One test for every field the gem reads or is given.
  def self.blank?(value) = value.nil? || value.to_s.match?(BLANK)
end
