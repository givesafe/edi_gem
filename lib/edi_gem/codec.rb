# frozen_string_literal: true

require "date"

module EdiGem
  # The X12 code sets, shared by every schema: a JSON vendor's benefit "code" is an EB01 and its
  # error "code" an AAA03. A source with its own values registers its own codec.
  module Codec
    # EB01 carries two things: ten values say whether the person is covered, the rest describe a
    # term of the plan (a co-payment, a deductible). Only these ten are statuses.
    ELIGIBILITY_STATUS = {
      "1" => :active, "2" => :active, "3" => :active, "4" => :active, "5" => :active,
      "6" => :inactive, "7" => :inactive, "8" => :inactive,
      "I" => :non_covered, "V" => :cannot_process
    }.freeze

    # The rest of EB01, in full.
    BENEFIT_TYPE = {
      "A" => :co_insurance, "B" => :co_payment, "C" => :deductible, "CB" => :coverage_basis,
      "D" => :benefit_description, "E" => :exclusions, "F" => :limitations,
      "G" => :out_of_pocket, "H" => :unlimited, "J" => :cost_containment, "K" => :reserve,
      "L" => :primary_care_provider, "M" => :pre_existing_condition,
      "MC" => :managed_care_coordinator, "N" => :restricted_to_provider,
      "O" => :not_medically_necessary, "P" => :benefit_disclaimer,
      "Q" => :second_surgical_opinion, "R" => :other_payer, "S" => :prior_year_history,
      "T" => :card_lost_or_stolen, "U" => :contact_entity, "W" => :other_data_source,
      "X" => :health_care_facility, "Y" => :spend_down
    }.freeze

    # Two codecs over one element. A code neither table names is kept as-is on the benefit side.
    EB01_STATUS = ->(value) { ELIGIBILITY_STATUS[value.to_s] }

    # The status code itself, kept because 5, 7 and 8 say more than active or inactive: the payer
    # is investigating, or updating its records.
    EB01_STATUS_CODE = ->(value) { value.to_s if ELIGIBILITY_STATUS.key?(value.to_s) }

    EB01_BENEFIT = lambda do |value|
      return nil if value.nil? || ELIGIBILITY_STATUS.key?(value.to_s)

      BENEFIT_TYPE.fetch(value.to_s, value)
    end

    # AAA03 reject reasons. A code not named here passes through as its raw string.
    REJECT_REASON = {
      "42" => :payer_unavailable, "43" => :provider_not_on_file, "45" => :provider_not_eligible,
      "50" => :provider_not_authorized, "51" => :provider_not_eligible,
      "58" => :date_of_birth_mismatch, "62" => :date_out_of_range,
      "64" => :member_id_invalid, "65" => :name_mismatch,
      "67" => :subscriber_not_found, "68" => :duplicate_subscriber,
      "71" => :date_of_birth_mismatch, "72" => :member_id_invalid,
      "73" => :name_mismatch, "75" => :subscriber_not_found,
      "76" => :duplicate_subscriber, "78" => :subscriber_not_in_plan,
      "15" => :required_data_missing, "33" => :input_errors,
      "41" => :authorization_restricted,
      "57" => :invalid_date_of_service, "60" => :date_out_of_range,
      "63" => :date_out_of_range, "77" => :patient_not_found,
      "79" => :invalid_participant, "80" => :payer_unavailable,
      "97" => :provider_address_invalid,
      "04" => :too_many_patients, "35" => :out_of_network,
      "44" => :provider_name_mismatch, "46" => :provider_phone_mismatch,
      "47" => :provider_state_mismatch, "49" => :provider_not_primary_care,
      "52" => :provider_not_enrolled_on_date, "53" => :provider_type_mismatch,
      "56" => :invalid_date_of_service, "61" => :date_of_death_conflict,
      "74" => :gender_missing, "T4" => :payer_identifier_missing
    }.freeze

    # Published AAA03 values with no documented meaning, deliberately left unnamed rather than
    # guessed. A spec pins REJECT_REASON and this list against the vendor's published enum.
    UNNAMED_REASONS = %w[48 54 55 66 69 70 98 AA AE AF AG AO CI E8 IA MA].freeze

    YES_NO = { "Y" => true, "N" => false, "U" => nil, "W" => nil }.freeze

    # A repeated element: X12 joins it with the ISA11 separator, JSON sends a list. Both
    # decode to a list.
    REPETITION = "^"

    CODES = lambda do |value|
      return nil if value.nil? || value == ""

      value.is_a?(Array) ? value : value.to_s.split(REPETITION)
    end

    # A date is D8 (one day) or RD8 ("YYYYMMDD-YYYYMMDD"), and JSON vendors pass either under one
    # key. A single date is a start and says nothing about the end.
    RD8 = /\A(?<start>\d{8})-(?<end>\d{8})\z/

    RD8_START = ->(value) { value.to_s[RD8, :start] || value }

    RD8_END = ->(value) { value.to_s[RD8, :end] }

    # A date-information object (Stedi's planDateInformation, benefitsDateInformation) read as one
    # span. Its own begin wins, the benefit's over the member's over the plan's; a period key's
    # start is the fallback. Its end is the earliest end it sends, since coverage stops at the
    # first. Stedi's list of ends also names policyEffective, which is a start; it is not read.
    SPAN_BEGINS = %w[benefitBegin eligibilityBegin planBegin].freeze
    SPAN_ENDS = %w[benefitEnd eligibilityEnd planEnd policyExpiration].freeze
    SPAN_PERIODS = %w[benefit eligibility plan].freeze
    DAY = /\A\d{8}\z/

    SPAN_BEGIN = ->(dates) { span_days(dates, SPAN_BEGINS, RD8_START).first }
    SPAN_END = ->(dates) { span_days(dates, SPAN_ENDS, RD8_END).min }

    # The payer a benefit line names as primary (2120C, `benefitsRelatedEntities`), which need not
    # be the payer that answered. Only a PI qualifier makes the value a payer code.
    PRIMARY_PAYER = "Primary Payer"

    PAYOR_IDENTIFICATION = "PI"

    PRIMARY_PAYER_OF = lambda do |entities|
      listed = entities.is_a?(Array) ? entities : [entities]
      listed.find { |entity| entity.is_a?(Hash) && entity["entityIdentifier"] == PRIMARY_PAYER }
    end

    PRIMARY_PAYER_CODE = lambda do |entities|
      payer = PRIMARY_PAYER_OF.call(entities)
      payer["entityIdentificationValue"] if payer&.fetch("entityIdentification", nil) == PAYOR_IDENTIFICATION
    end

    PRIMARY_PAYER_NAME = ->(entities) { PRIMARY_PAYER_OF.call(entities)&.fetch("entityName", nil) }

    REGISTRY = { eb01_status: EB01_STATUS, eb01_status_code: EB01_STATUS_CODE, eb01_benefit: EB01_BENEFIT,
                 aaa03: REJECT_REASON, yes_no: YES_NO, codes: CODES, rd8_start: RD8_START, rd8_end: RD8_END,
                 span_begin: SPAN_BEGIN, span_end: SPAN_END,
                 primary_payer_code: PRIMARY_PAYER_CODE, primary_payer_name: PRIMARY_PAYER_NAME }.freeze

    DAY_FORMAT = "%Y%m%d"

    # A YYYYMMDD string that names a real day, as a Date; anything else (a number included) is nil.
    def self.day(value)
      Date.strptime(value, DAY_FORMAT) if value.is_a?(String) && value.match?(DAY)
    rescue Date::Error
      nil
    end

    # A day as X12 writes one, YYYYMMDD: a Date (anything answering strftime) formatted, anything
    # else as its text, nil as nil.
    # Callers hold a day as a Date or as text they pass through: a YYYYMMDD day, an X12 range
    # (YYYYMMDD-YYYYMMDD, which a 270's DTP carries) or a hyphenated day Identity strips. The two
    # are Ruby's Date and String, so there is no class of ours to send the message to; the same
    # respond_to? was written out in Coverage, Identity and Inquiry in old code, and is one here.
    # :reek:ManualDispatch
    def self.yyyymmdd(date) = date.respond_to?(:strftime) ? date.strftime(DAY_FORMAT) : date&.to_s

    # The days a span's `keys` name, then that end (`period_end`) of each period, in that order; only
    # real YYYYMMDD strings. None when `dates` is not a hash.
    def self.span_days(dates, keys, period_end)
      return [] unless dates.is_a?(Hash)

      (dates.values_at(*keys) + dates.values_at(*SPAN_PERIODS).map(&period_end)).select { |day| day.to_s.match?(DAY) }
    end

    # A codec is a lookup table, or a rule when the mapping is not one value to one value.
    def self.decode(name, value)
      return value if name.nil?

      table = REGISTRY.fetch(name) { raise ArgumentError, "unknown codec #{name}" }
      table.respond_to?(:call) ? table.call(value) : table.fetch(value.to_s, value)
    end
  end
end
