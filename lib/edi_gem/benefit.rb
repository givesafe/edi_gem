# frozen_string_literal: true

module EdiGem
  # One benefit line the payer reported, together with the plan, payer and subscriber it belongs
  # to. The named readers are the shared vocabulary every schema maps into; any other field a
  # schema declares is still readable through #[].
  #
  # Several Benefits with one payer are the several things one plan covers, not several plans.
  class Benefit
    include Concealed

    # `status` and `benefit_type` are the two halves of EB01; a line carries one or the other, and
    # `status_code` the EB01 status itself. `coverage_ends_on` is the earliest of the plan's ends,
    # and `line_begins_on` and `line_ends_on` the line's own dates (see Coverage).
    # The `matched_*` fields are what the payer holds on record for the person it matched, so a
    # caller can confirm a discovery match before using it.
    CORE_FIELDS = %i[status status_code benefit_type
                     plan_name plan_number group_description member_id state_insurance_id
                     payer_name payer_code primary_payer_code primary_payer_name
                     service_types insurance_type in_network begins_on ends_on coverage_ends_on
                     line_begins_on line_ends_on
                     share_of_cost confidence confidence_reason
                     matched_first_name matched_last_name matched_date_of_birth
                     matched_address_line1 matched_address_line2 matched_city matched_state
                     matched_postal_code].freeze

    CORE_FIELDS.each { |field| define_method(field) { @attributes[field] } }

    attr_reader :attributes

    def initialize(attributes)
      @attributes = attributes
    end

    def [](field)
      @attributes[field.to_sym]
    end

    def active?
      @attributes[:status] == :active
    end

    # Whether the payer sent a benefit line, rather than only the plan around one.
    def line?
      !(@attributes[:status].nil? && @attributes[:benefit_type].nil?)
    end

    # Holds PHI, so only field names are printed, never values.
    def concealed_inspect
      "#<#{self.class} #{@attributes.keys.join(",")}>"
    end
  end
end
