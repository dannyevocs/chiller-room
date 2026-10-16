-- Training content for the inspect panel: one entry per inspect id (the "pick"
-- each object carries from chiller_hifi.blend). Readings shown with these are
-- simulated training data, never live plant values.

export type Entry = {
    title: string,
    kind: string, -- the chip under the title
    purpose: string,
    points: { string },
    valve: boolean?, -- shows an open/close control
    training: boolean?, -- its handwheel turns when operated
    safety: string?, -- an electrical or safety note, shown highlighted
    issues: { string }?, -- Equipment Knowledge Mode: common problems
    checks: { string }?, -- Equipment Knowledge Mode: what technicians inspect
}

local T: { [string]: Entry } = {}

T["chiller:CH-1"] = {
    title = "CH-1 Centrifugal Water-Cooled Chiller",
    kind = "CHILLER",
    purpose = "Removes heat from the data hall's chilled water and rejects it to the condenser water, which carries it to the cooling tower.",
    points = {
        "Evaporator (insulated shell): refrigerant boils at low pressure and chills the water from 54 to 44 °F.",
        "Compressor and motor (top): raise the refrigerant vapour's pressure and temperature.",
        "Condenser (front shell): the hot vapour condenses, warming the condenser water from 85 to 95 °F.",
        "Water boxes (bolted ends): the water passes through the tubes; the covers come off for tube cleaning.",
        "Refrigerant R-1233zd(E): low-pressure; the room has a leak monitor and low-level exhaust.",
    },
}
T["panel:CH1-CP"] = {
    title = "CH-1 Control Panel",
    kind = "CONTROLS",
    purpose = "The chiller's own controller: it stages the compressor to hold the leaving chilled water setpoint and protects the machine.",
    points = {
        "Screen: leaving and entering water temperatures, load, power and alarms.",
        "Green lights: running and normal. Amber: a warning to review.",
        "The red E-stop stops the chiller only; it is not an electrical isolation point.",
    },
    safety = "Training display only. Never use the E-stop or change setpoints without authorization.",
}

local function pump(tag: string, service: string, circuit: string, duty: boolean): Entry
    return {
        title = tag .. "  " .. service .. " Pump",
        kind = "PUMP · " .. (if duty then "DUTY" else "STANDBY"),
        purpose = if circuit == "CHW"
            then "Circulates chilled water: draws data hall return water and pushes it through the chiller's evaporator."
            else "Circulates condenser water: draws water returning from the cooling tower and pushes it through the chiller's condenser.",
        points = {
            "End-suction centrifugal pump, driven by a TEFC motor through a flexible coupling (yellow guard).",
            "Inertia base on spring isolators keeps vibration out of the building.",
            "Suction: isolation valve, Y-strainer, gauge. Discharge: flex connector, check valve, butterfly valve, gauge.",
            if duty then "Duty pump: running on its drive (VFD) at variable speed." else "Standby pump: ready to start automatically if the duty pump fails.",
        },
    }
end
T["pump:CHWP-1"] = pump("CHWP-1", "Chilled Water", "CHW", true)
T["pump:CHWP-2"] = pump("CHWP-2", "Chilled Water", "CHW", false)
T["pump:CWP-1"] = pump("CWP-1", "Condenser Water", "CW", true)
T["pump:CWP-2"] = pump("CWP-2", "Condenser Water", "CW", false)

local function isolation(circuit: string, name: string, flowNote: string): Entry
    return {
        title = "CH-1 " .. circuit .. " Isolation Valve",
        kind = "BUTTERFLY VALVE · GEAR OPERATED",
        purpose = "Isolates the chiller's " .. name .. " connection so the chiller can be serviced without draining the system.",
        points = {
            "Gear operator: the red handwheel turns the disc a quarter turn over many handwheel turns.",
            flowNote,
            "Flanges either side; the gauge and thermometer below it read the water at the chiller.",
        },
        valve = true,
        training = true,
    }
end
T["valve:CH1-CHWS-IV"] = isolation("CHWS", "chilled water supply (outlet)", "Closing it with the chiller running stops evaporator flow: the chiller trips on low flow.")
T["valve:CH1-CHWR-IV"] = isolation("CHWR", "chilled water return (inlet)", "Closing it with the chiller running stops evaporator flow: the chiller trips on low flow.")
T["valve:CH1-CWS-IV"] = isolation("CWS", "condenser water supply (inlet)", "Closing it with the chiller running stops condenser flow: the chiller trips on high pressure.")
T["valve:CH1-CWR-IV"] = isolation("CWR", "condenser water return (outlet)", "Closing it with the chiller running stops condenser flow: the chiller trips on high pressure.")
local function suction(tag: string): Entry
    return {
        title = tag .. " Suction Isolation Valve",
        short = tag .. " Suction Valve", -- for markers
        kind = "BUTTERFLY VALVE · GEAR OPERATED",
        purpose = "Isolates the pump's suction so the pump or its strainer can be serviced.",
        points = {
            "Close the suction and discharge valves, lock out the pump, then drain before opening anything.",
            "Never close a running pump's suction: it starves and cavitates.",
        },
        valve = true,
        training = true,
    }
end
for _, tag in { "CHWP-1", "CHWP-2", "CWP-1", "CWP-2" } do
    T["valve:" .. tag .. "-SV"] = suction(tag)
    T["strainer:" .. tag] = {
        title = tag .. " Y-Strainer",
        kind = "STRAINER",
        purpose = "Catches debris before it reaches the pump impeller.",
        points = {
            "The angled leg holds a mesh screen; the cap at its end comes off to clean it.",
            "Clean it when the pressure drop across it rises (compare the suction gauge before and after).",
            "Isolate and drain the pump first.",
        },
    }
    T["gauge:" .. tag .. "-S"] = {
        title = tag .. " Suction Pressure Gauge",
        kind = "GAUGE",
        purpose = "Shows the pressure at the pump inlet. With the discharge gauge it gives the pump's differential pressure.",
        points = { "A suction pressure well below normal suggests a clogged strainer or a closed valve." },
    }
end
T["valve:CHW-BYP"] = {
    title = "CHW Minimum-Flow Bypass Valve",
    kind = "CONTROL VALVE · MOTORIZED",
    purpose = "Opens to keep the chiller's minimum evaporator flow when the data hall's demand drops.",
    points = {
        "The orange actuator is driven by the plant controls; it modulates rather than just opening or closing.",
        "It connects chilled water supply back to the return upstream of the pumps.",
    },
    valve = true,
}
T["valve:CH1-CHWS-MV"] = {
    title = "CH-1 Motorized Isolation Valve",
    short = "CH-1 Motorized Valve", -- for markers
    kind = "BUTTERFLY VALVE · MOTORIZED",
    purpose = "Lets the plant controls open or isolate the chiller's chilled water automatically when it is staged on or off.",
    points = { "The orange actuator turns the valve; a manual override is on the actuator." },
    valve = true,
}
T["valve:CH1-CWS-BV"] = {
    title = "CH-1 Condenser Water Balancing Valve",
    short = "CW Balancing Valve", -- for markers
    kind = "BALANCING VALVE",
    purpose = "Set during commissioning to give the condenser its design flow.",
    points = { "Its handwheel has a memory stop; do not move it without the balancing report." },
    valve = true,
}

local pipeInfo: { [string]: { string } } = {
    CHWS = { "Chilled Water Supply (CHWS)", "About 44 °F water from the evaporator to the data hall's cooling units.", "Insulated with an aluminium jacket so it doesn't sweat (condensation)." },
    CHWR = { "Chilled Water Return (CHWR)", "About 54 °F water back from the data hall, through the air separator and CHW pumps into the evaporator.", "Insulated; the expansion tank connects to it at the air separator." },
    CWS = { "Condenser Water Supply (CWS)", "About 85 °F water from the cooling tower, through the CW pumps into the condenser.", "Open-loop tower water: not insulated, and strained before the pumps." },
    CWR = { "Condenser Water Return (CWR)", "About 95 °F water from the condenser back up to the cooling tower on the roof.", "It rises straight through the deck to the tower." },
}
for code, p in pipeInfo do
    T["pipe:" .. code] = { title = p[1], kind = "PIPING · " .. code, purpose = p[2], points = { p[3], "Use the pipe buttons below to highlight the whole circuit." } }
end
local function chillerGauge(code: string, name: string): Entry
    return {
        title = "CH-1 " .. code .. " Pressure Gauge and Thermometer",
        kind = "GAUGE",
        purpose = "Reads the water pressure and temperature at the chiller's " .. name .. " connection.",
        points = { "Compare inlet and outlet: the temperature difference shows how much heat the chiller is moving." },
    }
end
T["gauge:CH1-CHWS"] = chillerGauge("CHWS", "chilled water outlet")
T["gauge:CH1-CHWR"] = chillerGauge("CHWR", "chilled water inlet")
T["gauge:CH1-CWS"] = chillerGauge("CWS", "condenser water inlet")
T["gauge:CH1-CWR"] = chillerGauge("CWR", "condenser water outlet")

T["sep:AS-1"] = {
    title = "AS-1 Air and Dirt Separator",
    kind = "HYDRONIC ACCESSORY",
    purpose = "Removes entrained air from the chilled water return. The automatic vent on top lets the air out.",
    points = { "Air in a closed loop causes noise, corrosion and poor heat transfer.", "The expansion tank connects at its base: the point of no pressure change." },
}
T["tank:ET-1"] = {
    title = "ET-1 Expansion Tank",
    kind = "HYDRONIC ACCESSORY",
    purpose = "A pressure-rated bladder tank that absorbs the chilled water's expansion and contraction and holds system pressure.",
    points = { "Connected to the closed chilled water loop at the air separator.", "A waterlogged tank (failed bladder) makes system pressure swing." },
}
T["feeder:PF-1"] = {
    title = "PF-1 Chemical Pot Feeder",
    kind = "WATER TREATMENT",
    purpose = "Adds corrosion inhibitor to the closed chilled water loop.",
    points = { "Model note: its connection piping is not modelled." },
}
T["elec:VFD"] = {
    title = "Pump Variable Frequency Drives",
    kind = "ELECTRICAL · DRIVES",
    purpose = "One drive per pump: each varies its motor's speed to match the flow the plant needs, saving energy.",
    points = { "The display shows frequency (Hz), current and speed. Standby pumps show STOPPED." },
    safety = "Information only. Drives hold dangerous voltage after power is removed; only qualified persons open them.",
}
T["elec:DS-PUMP"] = {
    title = "Pump Local Disconnect Switches",
    kind = "ELECTRICAL · DISCONNECT",
    purpose = "A lockable switch within sight of each pump motor, used to isolate it for lockout/tagout.",
    points = { "The red handle is lockable in OFF." },
    safety = "Information only. Lockout/tagout is performed by authorized persons following site procedure.",
}
T["elec:DS-CH1"] = {
    title = "CH-1 Fused Disconnect",
    kind = "ELECTRICAL · DISCONNECT",
    purpose = "Isolates power to the chiller for maintenance.",
    points = { "Conduit runs overhead to the chiller's control panel." },
    safety = "Information only. Never operate under load except in an emergency; follow lockout/tagout.",
}
T["elec:MCC-1"] = {
    title = "MCC-1 Motor Control Center",
    kind = "ELECTRICAL · 480 V",
    purpose = "Distributes 480 V power to the plant's motors and drives through breakers and starters in each section.",
    points = { "Pilot lights: green running, amber warning, red tripped or off.", "The hatched floor area is its required working clearance: keep it clear.", "Power arrives from above: the conduit from its top box to the ceiling carries the 480 V feeder." },
    safety = "Information only. Arc flash hazard: only qualified persons in PPE work on or open this equipment.",
}
T["elec:ESD-1"] = {
    title = "Refrigeration Emergency Shutoff",
    kind = "SAFETY",
    purpose = "Stops the refrigeration machinery in an emergency such as a refrigerant leak. It is at the exit door by code.",
    points = { "Use it, then leave the room and report the emergency." },
}
T["monitor:RLM-1"] = {
    title = "RLM-1 Refrigerant Leak Monitor",
    kind = "SAFETY",
    purpose = "Samples the air for refrigerant. On alarm it sounds the horn/strobe, starts the emergency exhaust and alerts the operators.",
    points = { "The sensor tubing runs to the low point near the chiller: the refrigerant is heavier than air." },
}
T["safety:FA-1"] = {
    title = "Fire Alarm Pull Station",
    kind = "SAFETY",
    purpose = "Starts the building fire alarm manually.",
    points = {},
}
T["alarm:SILENCE"] = {
    title = "Plant Alarm Silence Switch",
    kind = "ALARMS",
    purpose = "Silences the plant alarm horn so you can think and talk. It does not clear the fault: the alarm stays on the screens until the cause is fixed.",
    points = { "Red beacon on top: it flashes while the horn sounds.", "Silence, then go and find the cause." },
}
T["safety:EYEWASH"] = {
    title = "Emergency Eyewash Station",
    kind = "SAFETY",
    purpose = "Flushes chemicals, refrigerant oil or debris out of the eyes. Water treatment chemicals and refrigerant are both eye hazards in this room.",
    points = {
        "Push the green flag: water runs from both heads and stays on, leaving both hands free.",
        "Hold your eyelids open and flush for a full 15 minutes, then get medical help.",
        "The green light and sign mark it; the green floor outline must stay clear.",
        "The yellow tag records the weekly activation test.",
    },
}
T["safety:RAIL"] = {
    title = "Guard Rail: Restricted Area",
    kind = "SAFETY",
    purpose = "Marks space that is not a walkway. Behind it the chiller's water connections are crowded with valves, gauges and pipe supports, and the gap behind the chiller is narrower than a safe aisle.",
    points = {
        "Entry is for maintenance staff under a work permit, with the equipment isolated as the job requires.",
        "You can inspect everything from the rail: click a valve or gauge to see its details and state.",
        "Safety-yellow rail: top rail at 1.07 m (42 in), mid rail, toe board.",
    },
}
T["fire:SPR"] = {
    title = "Fire Sprinkler Riser and System",
    kind = "FIRE PROTECTION",
    purpose = "A wet-pipe sprinkler system protects the room. The riser carries water up from the fire main to the main along the wall, then branch lines feed the upright heads under the deck.",
    points = {
        "OS&Y control valve: the exposed stem means it is open. It is supervised and normally locked open.",
        "The check valve stops backflow, the flow switch sends a waterflow alarm, and the gauge shows system pressure.",
        "Each head opens alone when its glass bulb bursts from heat. Heads are not set off all at once.",
        "Keep 450 mm (18 in) clear below the heads. Do not hang anything from sprinkler pipe.",
    },
    safety = "Information only. Only fire protection staff operate the control valve, with an impairment notice and a fire watch.",
}
T["vent:HP"] = {
    title = "Header High-Point Air Vents",
    kind = "AIR VENTS · REACHED FROM THE WALKWAY",
    purpose = "Air collects at the highest points of a water system. These automatic vents let it out of the four headers, so the pumps and chillers don't run with air in the water.",
    points = {
        "Each vent has a float inside: air lets it drop and open, water lifts it shut.",
        "A small ball valve under each vent isolates it for service; it is normally open.",
        "A vent that spits water, hisses all the time or sits wet has a fault: report it.",
        "Air in the system shows up as noisy pumps, gurgling pipes and poor flow.",
    },
}
T["safety:SCBA"] = {
    title = "SCBA Cabinet",
    kind = "EMERGENCY EQUIPMENT · SELF-CONTAINED BREATHING APPARATUS",
    purpose = "Breathing air for a rescue or an emergency shutdown in a room full of refrigerant. The vapor is heavier than air and pushes the oxygen out, low down first, and you can't sense it in time.",
    points = {
        "On a refrigerant alarm everyone leaves first. Only trained, fit-tested wearers use the SCBA.",
        "It hangs by the exit so you put it on before going back in, never deep inside the room.",
        "Inspected monthly: cylinder full (gauge in the green), mask clean, straps loose and ready, seal intact.",
        "Never go in alone: a second person, also equipped, waits outside.",
    },
}
T["safety:REFSTATION"] = {
    title = "Refrigerant Safety Station",
    kind = "EMERGENCY INFORMATION · LEAK RESPONSE",
    purpose = "What you need for a refrigerant leak, in one place by the door: the SCBA, the safety data sheets, the leak response steps and a handheld leak detector.",
    points = {
        "SDS for R-1233zd(E) and the compressor oil: health effects, first aid and firefighting.",
        "The handheld detector pinpoints a small leak once the room is safe; the wall monitor RLM-1 watches the whole room.",
        "If the monitor alarms: leave, shut the door, call for help, and confirm the exhaust fans are running.",
        "Report every alarm, even a short one.",
    },
}
T["pumpout:PO-1"] = {
    title = "Refrigerant Pump-Out Unit PO-1",
    short = "Pump-Out Unit PO-1",
    kind = "REFRIGERANT RECOVERY · CHILLER SERVICE",
    purpose = "A small condensing unit that moves a chiller's refrigerant charge into the storage receiver and back, so a machine can be opened for service without releasing refrigerant.",
    points = {
        "Permanent copper lines run overhead to CH-2 and CH-3; hoses connect it to the receiver's valves.",
        "Run only by certified technicians under the refrigerant handling procedure, never by operators alone.",
        "It pushes liquid out first, then pulls the vapor off and leaves the chiller under a vacuum.",
        "Valves closed and capped when idle. A hiss, frost or an oil stain at a fitting means a leak.",
    },
}
T["receiver:RS-1"] = {
    title = "Refrigerant Storage Receiver RS-1",
    short = "Receiver RS-1",
    kind = "PRESSURE VESSEL · REFRIGERANT STORAGE",
    purpose = "Holds a whole chiller charge (590 kg of R-1233zd(E)) while a machine is opened up for service.",
    points = {
        "Liquid and vapor valves on top; the sight glass on the west end shows the liquid level.",
        "Never fill past 80% liquid: refrigerant expands as it warms and can lift the relief valves.",
        "Dual relief valves on a three-way valve, vented outdoors like the chillers' own relief line.",
        "Check the shell, saddles and vent for corrosion or damage, and the relief valves' replacement date.",
    },
}
T["hoist:CH-1"] = {
    title = "CH-1 Monorail and Chain Hoist",
    short = "CH-1 Hoist",
    kind = "LIFTING EQUIPMENT · 2 TON MANUAL CHAIN HOIST",
    purpose = "A beam over CH-1 and its tube-pull area. The hoist lifts the heavy water box covers and handles tubes and parts during service.",
    points = {
        "Rated 2 tons: the capacity is marked on the beam. Never exceed it.",
        "Inspect before each use: hook and latch, chain wear and twists, the brake. Inspected and tagged yearly.",
        "Never lift a load over people or stand under one; keep the tube-pull area clear.",
        "Park the hook high and out of the way when it's not in use.",
    },
}
T["vent:RELIEF"] = {
    title = "Refrigerant Relief Vent Line",
    kind = "SAFETY",
    purpose = "Carries refrigerant from the chiller's pressure relief valves to discharge outdoors, away from doors, windows and air intakes, if vessel pressure gets too high.",
    points = {
        "Every vessel has a relief device. The vent line is sized so back pressure doesn't reduce the valves' capacity.",
        "No valves are allowed in the vent line, and it is supported so its weight doesn't rest on the relief valves.",
        "The roof end is turned down or capped against rain (simplified here: it ends at the deck).",
    },
    safety = "Information only. Never cap, plug or tap into a relief vent line.",
}
T["support"] = {
    title = "Pipe Supports",
    kind = "STRUCTURE",
    purpose = "Carry the weight of the pipes and their water: trapeze hangers where runs stack, clevis hangers on single runs, floor stands under the riser elbows.",
    points = { "Threaded rod hangs from the concrete deck." },
}

-- Simulated leaks (shown only during training scenarios)
local function leak(where: string, water: string): Entry
    return {
        title = "Water on the Floor",
        kind = "SIMULATED LEAK",
        purpose = "Water is dripping from " .. where .. " and pooling below it. " .. water,
        points = { "Note where it comes from, how fast it drips and how far the water has spread." },
        safety = "Do not tighten, open or repair anything under pressure. Keep clear of electrical equipment and mark the slip hazard.",
    }
end
T["leak:L1"] = leak("CHWP-1's shaft seal", "Chilled water: closed loop, treated with corrosion inhibitor.")
T["leak:L2"] = leak("the lower flange of CH-1's chilled water return isolation valve", "Chilled water: closed loop, treated with corrosion inhibitor.")
T["leak:L3"] = leak("CWP-1's shaft seal", "Condenser water: open loop from the cooling tower, chemically treated.")

-- Equipment Knowledge Mode: common issues and inspection points. General
-- guidance for training; review against the site's own procedures and the
-- manufacturers' manuals before using it on real equipment.
local function know(ids: { string }, issues: { string }, checks: { string })
    for _, id in ids do
        local e = T[id]
        if e ~= nil then
            e.issues = issues
            e.checks = checks
        end
    end
end
know({ "chiller:CH-1" },
    { "High condenser pressure from warm or low condenser water (tower or fouled tubes).", "Low evaporator pressure or temperature from low flow or low refrigerant charge.", "Oil temperature or pressure alarms; surge at low load and high lift." },
    { "Leaving and entering water temperatures against setpoint and design.", "Approach temperatures and the alarm history on the control panel.", "Unusual noise, vibration, oil or refrigerant leaks, and water box leaks." })
know({ "panel:CH1-CP" },
    { "Active or repeated alarms and warnings.", "Setpoint changed from the plant's standard.", "Limits active (current, condenser pressure) holding capacity back." },
    { "Status, load, temperatures, alarms; log them each round.", "The trend: is leaving water holding at setpoint?" })
know({ "pump:CHWP-1", "pump:CHWP-2", "pump:CWP-1", "pump:CWP-2" },
    { "Mechanical seal leaks at the shaft.", "Bearing noise, heat or vibration.", "Cavitation (gravel sound) from low suction pressure.", "Drive or motor overload trips." },
    { "Suction and discharge pressure: the difference is the pump's head.", "Seal area and base for water, the coupling guard in place.", "Motor and bearing noise, vibration and temperature by hand-held instruments, not touch.", "Standby pump: valves open and drive in AUTO, so it is ready." })
know({ "valve:CH1-CHWS-IV", "valve:CH1-CHWR-IV", "valve:CH1-CWS-IV", "valve:CH1-CWR-IV", "valve:CHWP-1-SV", "valve:CHWP-2-SV", "valve:CWP-1-SV", "valve:CWP-2-SV" },
    { "Left in the wrong position after maintenance.", "Packing or flange leaks.", "Seized operators from never being exercised." },
    { "Position matches the plant's normal line-up (usually fully open).", "Flanges and stem for leaks, the tag present and readable." })
know({ "valve:CHW-BYP", "valve:CH1-CHWS-MV" },
    { "Actuator failure or loss of signal leaves the valve in the wrong position.", "Manual override left engaged." },
    { "Commanded and actual positions agree.", "Actuator in AUTO; no alarms on it." })
know({ "valve:CH1-CWS-BV" },
    { "Moved from its set position, unbalancing the condenser flow." },
    { "Set position and memory stop unchanged since balancing." })
know({ "strainer:CHWP-1", "strainer:CHWP-2", "strainer:CWP-1", "strainer:CWP-2" },
    { "Clogged screen: falling pump suction pressure.", "Leaking cap or blowdown valve." },
    { "Suction pressure trend; cap and blowdown valve for leaks." })
know({ "gauge:CH1-CHWS", "gauge:CH1-CHWR", "gauge:CH1-CWS", "gauge:CH1-CWR", "gauge:CHWP-1-S", "gauge:CHWP-2-S", "gauge:CWP-1-S", "gauge:CWP-2-S" },
    { "Stuck or damaged gauges; a fogged face.", "Readings that disagree with the control panel's sensors." },
    { "Read and log the values; compare with design and with the panel.", "Report gauges that read wrong or can't be read." })
know({ "pipe:CHWS", "pipe:CHWR" },
    { "Torn insulation or jacket lets the pipe sweat and corrode.", "Leaks at flanges and fittings." },
    { "Insulation, jacket, hangers and labels intact; no drips or stains." })
know({ "pipe:CWS", "pipe:CWR" },
    { "Leaks at flanges and fittings; external corrosion.", "Scale and fouling from tower water." },
    { "Flanges and supports for leaks, rust and movement." })
know({ "sep:AS-1", "tank:ET-1" },
    { "Air vent leaking or stuck.", "Waterlogged expansion tank: system pressure swings." },
    { "System pressure steady; vent dry; no leaks." })
know({ "feeder:PF-1" },
    { "Leaking lid or valves.", "Inhibitor level not maintained." },
    { "Lid and valves closed and dry; dosing logged." })
know({ "elec:VFD", "elec:DS-PUMP", "elec:DS-CH1", "elec:MCC-1" },
    { "Trips and faults on drives and starters.", "Overheating; blocked ventilation or filters.", "Doors left open or covers missing." },
    { "From outside only: status lights and displays, alarms, doors closed.", "Clear working space in front; nothing stored there." })
know({ "monitor:RLM-1", "elec:ESD-1", "safety:FA-1" },
    { "A rising refrigerant reading; sensor out of calibration.", "Blocked access to the shutoff or pull station." },
    { "Reading normal and no alarms; calibration in date.", "Clear access; signs in place." })
know({ "safety:EYEWASH" },
    { "Path or floor outline blocked.", "Dust caps missing; weak or dirty flow.", "Weekly test tag out of date." },
    { "Clear path, caps on, bowl clean.", "Tag signed for this week; light working." })
know({ "fire:SPR" },
    { "Control valve not fully open or not supervised.", "Damaged, painted or obstructed heads." },
    { "Control valve open and locked; gauge reading normal.", "Clearance below the heads; nothing hung on the pipe." })
know({ "vent:HP" },
    { "A vent spitting or dripping water (a stuck float).", "Its isolating valve left shut, so air can't escape." },
    { "Vents dry and quiet; isolating valves open; no stains below." })
know({ "safety:SCBA", "safety:REFSTATION" },
    { "Cylinder low or the inspection tag out of date.", "Cabinet seal broken, mask missing or dirty.", "Station blocked, or the SDS binders missing." },
    { "Gauge in the green; tag signed this month; seal intact.", "Clear access to the station; SDS and detector in place." })
know({ "pumpout:PO-1", "receiver:RS-1" },
    { "Leaking valves, hoses or fittings (frost, oil stains, a rising refrigerant monitor).", "Receiver overfilled, or its relief valves past their date." },
    { "Valves closed and capped; hoses stowed; no oil or frost.", "Sight glass level logged; relief valve tag in date." })
know({ "hoist:CH-1" },
    { "Chain twisted, worn or kinked; a missing hook latch.", "Hook left hanging low in the walkway; inspection tag out of date." },
    { "Hook parked high, chains hanging free; latch present.", "Capacity marked; inspection tag current." })
know({ "vent:RELIEF" },
    { "A relief valve lifting or weeping (refrigerant monitor rises)." },
    { "Vent line intact and supported; the monitor reading normal." })


-- CH-2 and CH-3 (the chiller hall) are the same machine as CH-1: their entries are CH-1's with the tag swapped.
local function retag(e: any, n: number): any
    local function sw(x: any): any
        if type(x) == "string" then
            local out = string.gsub(x, "CH%-1", "CH-" .. n)
            out = string.gsub(out, "CH1%-", "CH" .. n .. "-")
            return out
        elseif type(x) == "table" then
            local t = {}
            for k, v in x do t[k] = sw(v) end
            return t
        end
        return x
    end
    return sw(e)
end
local base: { [string]: Entry } = {}
for id, e in T do
    if id == "chiller:CH-1" or id == "panel:CH1-CP" or id == "hoist:CH-1" or (string.sub(id, 1, 10) == "valve:CH1-" and string.sub(id, -3) == "-IV") or string.sub(id, 1, 10) == "gauge:CH1-" then
        base[id] = e
    end
end
for n = 2, 3 do
    for id, e in base do
        local nid = string.gsub(string.gsub(id, "CH%-1", "CH-" .. n), "CH1%-", "CH" .. n .. "-")
        T[nid] = retag(e, n)
    end
end
T["chiller:CH-3"].purpose = "The standby chiller: CH-3 is ready to start if CH-1 or CH-2 trips or the load grows. " .. T["chiller:CH-1"].purpose

return T
