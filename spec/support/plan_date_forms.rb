# frozen_string_literal: true

require "date"

# A plan's own dates come from its `plan` range when sent, else planBegin and planEnd, and never
# from the eligibility dates. Each form as Stedi sends planDateInformation, read the same by a
# check (CheckedPlan) and a discovery (MedicalPlan), with the [begins, ends] it must give. Made up.
module PlanDateForms
  ALL = {
    "a plan range" => [{ "plan" => "20250101-20251231", "eligibilityBegin" => "20240101" },
                       [Date.new(2025, 1, 1), Date.new(2025, 12, 31)]],
    "planBegin and planEnd" => [{ "planBegin" => "20250201", "planEnd" => "20251130",
                                  "eligibilityEnd" => "20250601" },
                                [Date.new(2025, 2, 1), Date.new(2025, 11, 30)]],
    "a plan range beside planBegin and planEnd" => [{ "plan" => "20250101-20251231", "planBegin" => "20250201",
                                                      "planEnd" => "20251130" },
                                                    [Date.new(2025, 1, 1), Date.new(2025, 12, 31)]],
    "a single plan day and a planEnd" => [{ "plan" => "20250101", "planEnd" => "20251130" },
                                          [Date.new(2025, 1, 1), Date.new(2025, 11, 30)]],
    "only eligibility dates" => [{ "eligibilityBegin" => "20250101", "eligibilityEnd" => "20251231" }, [nil, nil]]
  }.freeze
end
