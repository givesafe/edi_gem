# frozen_string_literal: true

module EdiGem
  # A field of a plan as a whole (payer_code, member_id, state_insurance_id, plan_name, ...): the
  # first of its benefits that holds it. The includer provides `benefits`.
  module PlanFields
    def [](field)
      benefits.each do |benefit|
        value = benefit[field]
        return value unless value.nil?
      end
      nil
    end
  end
end
