# frozen_string_literal: true

module EdiGem
  # The provider an inquiry is made on behalf of. Secrets a source needs for it live on
  # Credential, not here. A name is optional: Stedi finds the provider by NPI and advises
  # leaving it out. `address` is an Address. Each attribute is one field of the provider as
  # Stedi takes it, which reek counts as state. :reek:TooManyInstanceVariables
  class Provider
    attr_reader :npi, :organization_name, :first_name, :last_name,
                :tax_id, :address, :medicaid_number, :medicare_number

    def initialize(npi:, organization_name: nil, first_name: nil, last_name: nil,
                   tax_id: nil, address: nil, medicaid_number: nil, medicare_number: nil)
      @npi = npi
      @organization_name = organization_name
      @first_name = first_name
      @last_name = last_name
      @tax_id = tax_id
      @address = address
      @medicaid_number = medicaid_number
      @medicare_number = medicare_number
    end

    def to_h
      { npi: @npi, organizationName: @organization_name, firstName: @first_name,
        lastName: @last_name, taxId: @tax_id, address: @address&.to_stedi_h,
        medicaidProviderNumber: @medicaid_number, medicareProviderNumber: @medicare_number }.compact
    end
  end
end
