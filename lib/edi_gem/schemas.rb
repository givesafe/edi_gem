# frozen_string_literal: true

# The schemas shipped with the gem. An X12 source reuses :x12_271; a JSON source declares its
# own. The codecs are shared, because JSON vendors re-expose the X12 code sets.
EdiGem::Schema.define(:x12_271) do
  # A level's benefit lines and its dates: the subscriber's in loop 2000C, a dependent's in 2000D.
  lines = lambda do |level|
    benefit "2110#{level}/EB" do
      field :status, from: "EB01", codec: :eb01_status
      field :status_code, from: "EB01", codec: :eb01_status_code
      field :benefit_type, from: "EB01", codec: :eb01_benefit
      field :service_types, from: "EB03", codec: :codes
      field :insurance_type, from: "EB04"
      field :plan_name, from: "EB05"
      field :in_network, from: "EB12", codec: :yes_no
    end
  end

  dates = lambda do |level|
    benefit("2100#{level}/DTP[356]") { field :begins_on, from: "DTP03" }
    benefit("2100#{level}/DTP[357]") { field :ends_on, from: "DTP03" }
  end

  lines.call("C")

  benefit "2100C/NM1[IL]" do
    field :member_id, from: "NM109"
  end

  benefit "2100A/NM1[PR]" do
    field :payer_name, from: "NM103"
    field :payer_code, from: "NM109"
  end

  dates.call("C")

  # Share of cost (AMT*R): eligible, with an amount owed before coverage pays. Neither a refusal
  # nor plain active coverage.
  benefit "2110C/AMT[R]" do
    field :share_of_cost, from: "AMT02"
  end

  # The refusals at each level: the payer (2100A), the provider (2100B), the subscriber (2100C) and,
  # when the patient is a dependent, the dependent (2100D).
  { "A" => :payer, "B" => :provider, "C" => :subscriber, "D" => :dependent }.each do |level, refused_at|
    rejection "2100#{level}/AAA", level: refused_at do
      field :code, from: "AAA03", codec: :aaa03
      field :reason_code, from: "AAA03"
      field :followup, from: "AAA04"
    end
  end

  # When the patient is a dependent, their lines and dates are in loop 2000D.
  lines.call("D")
  dates.call("D")

  # The people the 271 names: NM1 (IL the subscriber, 03 a dependent), DMG and INS at each
  # level. INS02 is the relationship, INS03 and INS04 the maintenance codes.
  { "C" => [:subscriber, "IL"], "D" => [:dependent, "03"] }.each do |level, (role, entity)|
    person "2100#{level}/NM1[#{entity}]", role: role do
      field :last_name, from: "NM103"
      field :first_name, from: "NM104"
      field :middle_name, from: "NM105"
      field :suffix, from: "NM107"
      field :member_id, from: "NM109"
    end

    person "2100#{level}/DMG[D8]", role: role do
      field :date_of_birth, from: "DMG02"
    end

    person "2100#{level}/INS", role: role do
      field :relationship_code, from: "INS02"
      field :maintenance_type_code, from: "INS03"
      field :maintenance_reason_code, from: "INS04"
    end
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
    # The plan's own dates: its `plan` range when sent, else planBegin and planEnd. Never the
    # eligibility period or a line's dates.
    field :plan_begins_on, from: "plan", codec: :rd8_start
    field :plan_begins_on, from: "planBegin"
    field :plan_ends_on, from: "plan", codec: :rd8_end
    field :plan_ends_on, from: "planEnd"
    field :eligibility_ends_on, from: "eligibilityEnd"
    field :policy_effective_on, from: "policyEffective"
    field :policy_expires_on, from: "policyExpiration"
    field :coverage_ends_on, from: "", codec: :span_end
  end

  { "payer" => :payer, "provider" => :provider, "subscriber" => :subscriber,
    "dependents[]" => :dependent }.each do |lane, refused_at|
    rejection "#{lane}.aaaErrors[]", level: refused_at do
      field :code, from: "code", codec: :aaa03
      field :reason_code, from: "code"
      field :description, from: "description"
      field :followup, from: "followupAction"
      field :resolution, from: "possibleResolutions"
    end
  end

  # The subscriber is always the policyholder (18). A dependent's memberId is never sent; theirs
  # is the subscriber's.
  { "subscriber" => :subscriber, "dependents[]" => :dependent }.each do |address, role|
    person address, role: role do
      field :first_name, from: "firstName"
      field :last_name, from: "lastName"
      field :middle_name, from: "middleName"
      field :suffix, from: "suffix"
      field :date_of_birth, from: "dateOfBirth"
      field :member_id, from: "memberId"
      field :relationship_code, from: "relationToSubscriberCode"
      field :maintenance_type_code, from: "maintenanceTypeCode"
      field :maintenance_reason_code, from: "maintenanceReasonCode"
    end
  end

  # applicationMode is the vendor's label for the exchange, not proof of whether a real payer
  # was reached.
  detail do
    field :application_mode, from: "meta.applicationMode"
    field :trace_id, from: "meta.traceId"
    field :submitter_id, from: "meta.submitterId"
    field :control_number, from: "controlNumber"
    field :search_id, from: "eligibilitySearchId"
    field :warning_codes, from: "warnings", codec: :warning_codes
  end

  # The flat errors[] repeats the nested AAAs without their lane. Read as a fallback: only what
  # the lanes do not already hold is taken, and `location` ("Loop 2000A") recovers the lane.
  rejection "errors[]", level: :envelope, fallback: true do
    field :code, from: "code", codec: :aaa03
    field :reason_code, from: "code"
    field :description, from: "description"
    field :field, from: "field"
    field :followup, from: "followupAction"
    field :location, from: "location"
    field :resolution, from: "possibleResolutions"
  end
end

# Insurance discovery: an `items[]` of whole coverages, each with its own payer and subscriber.
#
# Discovery matches on demographics and can return false positives, so each FoundPlan carries the
# people the payer holds on record (name, birth date, address) for the caller to confirm.
EdiGem::Schema.define(:stedi_discovery) do
  benefit "items[]" do
    field :plan_number, from: "planInformation.planNumber"
    # The payer's own name for the program; the payer code alone does not identify it.
    field :group_description, from: "planInformation.groupDescription"

    # The state's Medicaid id for the person, distinct from the plan's member id. It can arrive
    # on an inactive coverage, so read it from every item.
    field :state_insurance_id, from: "planInformation.medicaidRecipientIdNumber"

    field :member_id, from: "subscriber.memberId"
    field :group_number, from: "subscriber.groupNumber"
    field :payer_name, from: "payer.name"
    field :payer_code, from: "payer.payorIdentification"
    # Same date fallbacks as the eligibility schema.
    field :begins_on, from: "planDateInformation.eligibilityBegin"
    field :begins_on, from: "planDateInformation.planBegin"
    field :begins_on, from: "planDateInformation.plan", codec: :rd8_start
    field :ends_on, from: "planDateInformation.planEnd"
    field :ends_on, from: "planDateInformation.plan", codec: :rd8_end
    # The plan's own dates, as the eligibility schema reads them.
    field :plan_begins_on, from: "planDateInformation.plan", codec: :rd8_start
    field :plan_begins_on, from: "planDateInformation.planBegin"
    field :plan_ends_on, from: "planDateInformation.plan", codec: :rd8_end
    field :plan_ends_on, from: "planDateInformation.planEnd"
    field :coverage_ends_on, from: "planDateInformation", codec: :span_end
    field :confidence, from: "confidence.level"
    field :confidence_reason, from: "confidence.reason"
  end

  # Each item is one coverage, read apart with its own people (FoundPlan), so a dependent's
  # missing field is never filled from the policyholder's.
  found_plan "items[]"
  { "items[].subscriber" => :subscriber, "items[].dependent" => :dependent }.each do |address, role|
    person address, role: role do
      field :first_name, from: "firstName"
      field :last_name, from: "lastName"
      field :middle_name, from: "middleName"
      field :suffix, from: "suffix"
      field :date_of_birth, from: "dateOfBirth"
      field :member_id, from: "memberId"
      field :relationship_code, from: "relationToSubscriberCode"
      field :maintenance_type_code, from: "maintenanceTypeCode"
      field :maintenance_reason_code, from: "maintenanceReasonCode"
      field :address_line1, from: "address.address1"
      field :address_line2, from: "address.address2"
      field :city, from: "address.city"
      field :state, from: "address.state"
      field :postal_code, from: "address.postalCode"
    end
  end

  # A separate block, because a field is addressed relative to its own record.
  benefit "items[].benefitsInformation[]" do
    field :status, from: "code", codec: :eb01_status
    field :status_code, from: "code", codec: :eb01_status_code
    field :benefit_type, from: "code", codec: :eb01_benefit
    field :service_types, from: "serviceTypeCodes", codec: :codes
    field :plan_name, from: "planCoverage"
    field :insurance_type, from: "insuranceType"
    field :primary_payer_code, from: "benefitsRelatedEntities", codec: :primary_payer_code
    field :primary_payer_name, from: "benefitsRelatedEntities", codec: :primary_payer_name
    # The line's own dates, which win over the plan's for that line.
    field :line_begins_on, from: "benefitsDateInformation", codec: :span_begin
    field :line_ends_on, from: "benefitsDateInformation", codec: :span_end
  end

  # A found plan's payer refusing our provider, on that plan alone.
  %w[items[].subscriber items[].dependent].each do |address|
    rejection "#{address}.responseProvider.aaaErrors[]", level: :provider do
      field :code, from: "code", codec: :aaa03
      field :reason_code, from: "code"
      field :description, from: "description"
      field :followup, from: "followupAction"
    end
  end

  # The flat list's `location` ("Loop 2100C") names the lane, so a subscriber not found reads as
  # not identified rather than as a refused request.
  rejection "errors[]", level: :envelope, fallback: true do
    field :code, from: "code", codec: :aaa03
    field :reason_code, from: "code"
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
    field :warning_codes, from: "warnings", codec: :warning_codes
  end
end
