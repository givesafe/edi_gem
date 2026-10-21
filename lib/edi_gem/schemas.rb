# frozen_string_literal: true

# The schemas shipped with the gem. An X12 source reuses :x12_271; a JSON source declares its
# own. The codecs are shared, because JSON vendors re-expose the X12 code sets.
EdiGem::Schema.define(:x12_271) do
  benefit "2110C/EB" do
    field :status, from: "EB01", codec: :eb01_status
    field :status_code, from: "EB01", codec: :eb01_status_code
    field :benefit_type, from: "EB01", codec: :eb01_benefit
    field :service_types, from: "EB03", codec: :codes
    field :insurance_type, from: "EB04"
    field :plan_name, from: "EB05"
    field :in_network, from: "EB12", codec: :yes_no
  end

  benefit "2100C/NM1[IL]" do
    field :member_id, from: "NM109"
  end

  benefit "2100A/NM1[PR]" do
    field :payer_name, from: "NM103"
    field :payer_code, from: "NM109"
  end

  benefit "2100C/DTP[356]" do
    field :begins_on, from: "DTP03"
  end

  benefit "2100C/DTP[357]" do
    field :ends_on, from: "DTP03"
  end

  # Share of cost (AMT*R): eligible, with an amount owed before coverage pays. Neither a refusal
  # nor plain active coverage.
  benefit "2110C/AMT[R]" do
    field :share_of_cost, from: "AMT02"
  end

  rejection "2100A/AAA", level: :payer do
    field :code, from: "AAA03", codec: :aaa03
    field :followup, from: "AAA04"
  end

  rejection "2100B/AAA", level: :provider do
    field :code, from: "AAA03", codec: :aaa03
    field :followup, from: "AAA04"
  end

  rejection "2100C/AAA", level: :subscriber do
    field :code, from: "AAA03", codec: :aaa03
    field :followup, from: "AAA04"
  end
end

EdiGem::Schema.define(:stedi) do
  benefit "benefitsInformation[]" do
    field :status, from: "code", codec: :eb01_status
    field :status_code, from: "code", codec: :eb01_status_code
    field :benefit_type, from: "code", codec: :eb01_benefit
    field :service_types, from: "serviceTypeCodes", codec: :codes
    field :plan_name, from: "planCoverage"
    field :insurance_type, from: "insuranceType"
    field :in_network, from: "inPlanNetworkIndicatorCode", codec: :yes_no
    field :primary_payer_code, from: "benefitsRelatedEntities", codec: :primary_payer_code
    field :primary_payer_name, from: "benefitsRelatedEntities", codec: :primary_payer_name
    # The line's own dates, which win over the plan's for that line.
    field :line_begins_on, from: "benefitsDateInformation", codec: :span_begin
    field :line_ends_on, from: "benefitsDateInformation", codec: :span_end
  end

  benefit "planInformation" do
    field :plan_number, from: "planNumber"
    field :group_number, from: "groupNumber"
    field :group_description, from: "groupDescription"
    field :state_insurance_id, from: "medicaidRecipientIdNumber"
  end

  # The payer's own id for the person, used for later checks.
  benefit "subscriber" do
    field :member_id, from: "memberId"
    field :plan_number, from: "planNumber"
    field :group_number, from: "groupNumber"
  end

  benefit "payer" do
    field :payer_name, from: "name"
    field :payer_code, from: "payorIdentification"
  end

  # Several date keys can appear and the earliest end governs: `coverage_ends_on` is that end,
  # and the rest are readable through Benefit#[]. `plan` (one date or a range) is the fallback when
  # the payer sends no begin or end of its own.
  benefit "planDateInformation" do
    field :begins_on, from: "eligibilityBegin"
    field :begins_on, from: "planBegin"
    field :begins_on, from: "plan", codec: :rd8_start
    field :ends_on, from: "planEnd"
    field :ends_on, from: "plan", codec: :rd8_end
    field :plan_begins_on, from: "plan", codec: :rd8_start
    field :plan_ends_on, from: "plan", codec: :rd8_end
    field :eligibility_ends_on, from: "eligibilityEnd"
    field :policy_effective_on, from: "policyEffective"
    field :policy_expires_on, from: "policyExpiration"
    field :coverage_ends_on, from: "", codec: :span_end
  end

  rejection "payer.aaaErrors[]", level: :payer do
    field :code, from: "code", codec: :aaa03
    field :description, from: "description"
    field :followup, from: "followupAction"
    field :resolution, from: "possibleResolutions"
  end

  rejection "provider.aaaErrors[]", level: :provider do
    field :code, from: "code", codec: :aaa03
    field :description, from: "description"
    field :followup, from: "followupAction"
    field :resolution, from: "possibleResolutions"
  end

  rejection "subscriber.aaaErrors[]", level: :subscriber do
    field :code, from: "code", codec: :aaa03
    field :description, from: "description"
    field :followup, from: "followupAction"
    field :resolution, from: "possibleResolutions"
  end

  # applicationMode is the vendor's label for the exchange, not proof of whether a real payer
  # was reached.
  detail do
    field :application_mode, from: "meta.applicationMode"
    field :trace_id, from: "meta.traceId"
    field :submitter_id, from: "meta.submitterId"
    field :control_number, from: "controlNumber"
    field :search_id, from: "eligibilitySearchId"
  end

  # The flat errors[] repeats the nested AAAs without their lane. Read as a fallback: only what
  # the lanes do not already hold is taken, and `location` ("Loop 2000A") recovers the lane.
  rejection "errors[]", level: :envelope, fallback: true do
    field :code, from: "code", codec: :aaa03
    field :description, from: "description"
    field :field, from: "field"
    field :followup, from: "followupAction"
    field :location, from: "location"
    field :resolution, from: "possibleResolutions"
  end
end

# Insurance discovery: an `items[]` of whole coverages, each with its own payer and subscriber.
#
# Discovery matches on demographics and can return false positives, so the `matched_*` fields
# carry what the payer holds on record (name, birth date, address) for the caller to confirm. When
# the patient is a dependent, Stedi puts them in `dependent` and the policyholder in `subscriber`,
# so the dependent is the person matched.
EdiGem::Schema.define(:stedi_discovery) do
  benefit "items[]" do
    field :plan_number, from: "planInformation.planNumber"
    # The payer's own name for the program; the payer code alone does not identify it.
    field :group_description, from: "planInformation.groupDescription"

    # The state's Medicaid id for the person, distinct from the plan's member id. It can arrive
    # on an inactive coverage, so read it from every item.
    field :state_insurance_id, from: "planInformation.medicaidRecipientIdNumber"

    field :member_id, from: "subscriber.memberId"
    field :payer_name, from: "payer.name"
    field :payer_code, from: "payer.payorIdentification"
    # Same date fallbacks as the eligibility schema.
    field :begins_on, from: "planDateInformation.eligibilityBegin"
    field :begins_on, from: "planDateInformation.planBegin"
    field :begins_on, from: "planDateInformation.plan", codec: :rd8_start
    field :ends_on, from: "planDateInformation.planEnd"
    field :ends_on, from: "planDateInformation.plan", codec: :rd8_end
    field :plan_begins_on, from: "planDateInformation.plan", codec: :rd8_start
    field :plan_ends_on, from: "planDateInformation.plan", codec: :rd8_end
    field :coverage_ends_on, from: "planDateInformation", codec: :span_end
    field :confidence, from: "confidence.level"
    field :confidence_reason, from: "confidence.reason"
    %w[subscriber dependent].reverse_each do |person|
      field :matched_first_name, from: "#{person}.firstName"
      field :matched_last_name, from: "#{person}.lastName"
      field :matched_date_of_birth, from: "#{person}.dateOfBirth"
      field :matched_address_line1, from: "#{person}.address.address1"
      field :matched_address_line2, from: "#{person}.address.address2"
      field :matched_city, from: "#{person}.address.city"
      field :matched_state, from: "#{person}.address.state"
      field :matched_postal_code, from: "#{person}.address.postalCode"
    end
  end

  # A separate block, because a field is addressed relative to its own record.
  benefit "items[].benefitsInformation[]" do
    field :status, from: "code", codec: :eb01_status
    field :status_code, from: "code", codec: :eb01_status_code
    field :benefit_type, from: "code", codec: :eb01_benefit
    field :service_types, from: "serviceTypeCodes", codec: :codes
    field :plan_name, from: "name"
    field :insurance_type, from: "insuranceType"
    field :primary_payer_code, from: "benefitsRelatedEntities", codec: :primary_payer_code
    field :primary_payer_name, from: "benefitsRelatedEntities", codec: :primary_payer_name
    # The line's own dates, which win over the plan's for that line.
    field :line_begins_on, from: "benefitsDateInformation", codec: :span_begin
    field :line_ends_on, from: "benefitsDateInformation", codec: :span_end
  end

  # Stedi's discovery answer has only the flat list. Its `location` ("Loop 2100C") names the lane,
  # so a subscriber not found reads as not identified rather than as a refused request.
  rejection "errors[]", level: :envelope, fallback: true do
    field :code, from: "code", codec: :aaa03
    field :description, from: "description"
    field :field, from: "field"
    field :followup, from: "followupAction"
    field :location, from: "location"
  end

  detail do
    field :application_mode, from: "meta.applicationMode"
    field :trace_id, from: "meta.traceId"
    field :discovery_id, from: "discoveryId"
    field :coverages_found, from: "coveragesFound"
  end
end
