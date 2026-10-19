# frozen_string_literal: true

module EdiGem
  # The provider an inquiry is made on behalf of. Secrets a source needs for it live on
  # Credential, not here.
  class Provider
    attr_reader :npi, :organization_name, :first_name, :last_name,
                :tax_id, :medicaid_number, :medicare_number

    def initialize(npi:, organization_name: nil, first_name: nil, last_name: nil,
                   tax_id: nil, medicaid_number: nil, medicare_number: nil)
      ensure_named(organization_name, last_name)

      @npi = npi
      @organization_name = organization_name
      @first_name = first_name
      @last_name = last_name
      @tax_id = tax_id
      @medicaid_number = medicaid_number
      @medicare_number = medicare_number
    end

    def to_h
      { npi: @npi, organizationName: @organization_name, firstName: @first_name,
        lastName: @last_name, taxId: @tax_id, medicaidProviderNumber: @medicaid_number,
        medicareProviderNumber: @medicare_number }.compact
    end

    private

    # Every source requires a provider name, so a nameless provider is refused at construction.
    def ensure_named(organization_name, last_name)
      return unless blank?(organization_name) && blank?(last_name)

      raise ArgumentError, "a provider needs a name: organization_name, or last_name for an " \
                           "individual. NM103 carries it and no source accepts a request without it"
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end
  end
end
