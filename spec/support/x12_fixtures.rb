# frozen_string_literal: true

# A 271 is only parseable once the ISA segment is exactly right -- the delimiters are read out of
# it by offset, so a fixture that is one character short parses as nothing at all.
module X12Fixtures
  ISA = ["ISA", "00", " " * 10, "00", " " * 10, "ZZ", "SENDER".ljust(15), "ZZ",
         "RECEIVER".ljust(15), "260903", "1200", "^", "00501", "000000001", "0", "P", ":"]
        .join("*")

  def x12_271(*segments)
    "#{ISA}~#{segments.join}"
  end

  # An active plan-coverage benefit for a subscriber, under the loops a 271 puts them in.
  def covered_271
    x12_271("GS*HB*SENDER*RECEIVER*20260903*1200*1*X*005010X279A1~",
            "ST*271*0001~",
            "HL*1**20*1~", "NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*38333~",
            "HL*2*1*21*1~", "NM1*1P*2*EXAMPLECLINIC*****XX*1234567890~",
            "HL*3*2*22*0~", "NM1*IL*1*LOVELACE*ADA****MI*MEM123~",
            "EB*1**30**EXAMPLE MANAGED CARE*****Y~",
            "SE*9*0001~")
  end

  # The worked 271 from Office Ally's published 270/271 companion guide, trimmed to the
  # segments this gem reads.
  OFFICE_ALLY_SEGMENTS = [
    "GS*HB*940360524*OFFICEALLYRT*20121203*1131300*58486*X*005010X279A1~",
    "ST*271*584863044*005010X279A1~",
    "BHT*0022*11*6B2BA26FF7DF482D8A1D291334ED96*20121203*1131300~",
    "HL*1**20*1~",
    "NM1*PR*2*BLUE SHIELD SOMEWHERE*****24*940360524~",
    "PER*IC*CUSTOMER SERVICE*TE*8006762583~",
    "HL*2*1*21*1~",
    "NM1*1P*2*SOME COMMUNITY HOSPITAL*****XX*1166606569~",
    "HL*3*2*22*1~",
    "NM1*IL*1*LAST*FIRST****MI*UUE12345678U5~",
    "DMG*D8*19770915*F~",
    "DTP*291*D8*20121203~",
    "DTP*356*D8*20070701~",
    "DTP*357*D8*99991231~",
    "EB*1**30*HM*EXAMPLE HMO~",
    "SE*15*584863044~"
  ].freeze

  def office_ally_271 = x12_271(*OFFICE_ALLY_SEGMENTS)

  # A share of cost: eligible, and owing a spend-down before the coverage pays. Synthetic values.
  def share_of_cost_271
    x12_271("GS*HB*99999*SUBMITTER*20260903*1200*1*X*005010X279A1~",
            "ST*271*0001*005010X279A1~",
            "HL*1**20*1~", "NM1*PR*2*EXAMPLE MEDICAID*****PI*99999~",
            "HL*2*1*21*1~", "NM1*1P*2*TESTPROVNAME*****XX*0000000501~",
            "HL*3*2*22*0~", "NM1*IL*1*LAST*FIRST****MI*TEST77777~",
            "DMG*D8*19811216*F~",
            "DTP*356*D8*20120701~",
            "EB*1**30**EXAMPLE MEDICAID~",
            "AMT*R*20~",
            "SE*12*0001~")
  end

  # The same shape, refused at the subscriber level: AAA03 72 is an invalid member id.
  def rejected_271
    x12_271("ST*271*0001~",
            "HL*1**20*1~", "NM1*PR*2*EXAMPLE HEALTH PLAN*****PI*38333~",
            "HL*3*2*22*0~", "AAA*Y**72*C~",
            "SE*5*0001~")
  end
end
