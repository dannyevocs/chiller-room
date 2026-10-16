-- Technician training scenarios, started from the toolbar's "Begin Simulation"
-- button. Nothing here runs until then; ending the simulation puts the plant
-- back to normal.
--
-- Each scenario is a short list of steps, one thing at a time, run by one engine:
--   alarm   an alarm horn the trainee silences at the red ALARM SILENCE switch
--   game    walk up to the glowing target and click it: a mini game opens (games.luau)
--   goto    walk up to the glowing equipment and click it (its panel shows the readings)
--   check   a stop on the inspection round: walk up to the glowing equipment and
--           click it, then say whether it looks normal or name the problem
-- Clicks on goto/check targets count only from within reach (main.luau's REACH).
--   find    search a zone on the floor for something and click it (no exact
--           marker until the trainee asks for one or misses twice)
--   choose  a question with three short answers, scored, with feedback
-- Markers (Sim.markers) tell main.luau what to point at; points, streaks and
-- toasts (Sim.popToast) make progress visible. A scenario may also lay
-- simulated effects over the plant: screen and gauge values (art.luau Effects),
-- panel readings, a valve's position, a leak.
--
-- Every reading and fault is simulated training data. The procedures and
-- responses are general good practice, not a site's procedures: review them
-- against the facility's own SOPs, EOPs and lockout/tagout program.

local Art = require("art")
local Training = require("training")
local Games = require("games")

local Sim = {}

export type Line = { text: string, tone: string?, kind: string? } -- kind: "head", "check", "big", "rule", "score", "progress", "objective", "stars"; tone: "good", "bad", "warn", "muted", "accent"
export type Button = { label: string, action: string, style: string? } -- style: "primary", "choice", "quiet", "abc" (label "A|text"), "hint"
export type Card = { title: string, sub: string, lines: { Line }, buttons: { Button } }
export type Extra = { heading: string, lines: { Line }, buttons: { Button } }
export type Reading = { label: string, value: string }
export type Toast = { text: string, tone: string, points: number }
export type Markers = { targets: { string }, done: { [string]: boolean }, zone: string?, zoneRadius: number, red: boolean? }

type Choice = { label: string, correct: boolean, feedback: string, unsafe: boolean? }
type Step = {
    kind: string,
    objective: string, -- short: what to do now
    detail: string?, -- one muted line under it
    cat: string?, -- scoring category
    points: number?,
    targets: { string }?, -- goto / check / find
    needAll: boolean?, -- goto / check: every target
    accepts: ((id: string) -> boolean)?, -- find: where the answer button shows
    answer: string?, -- find: the answer button's label
    success: string?, -- shown once the step is done
    hint: string?, -- find: after a miss
    conceal: boolean?, -- find: hide equipment names until answered
    direct: boolean?, -- find: clicking an accepted object answers at once (no panel button)
    game: string?, -- game: which mini game the target opens
    ctx: any?, -- game: its data (readings, clues, pump swap...)
    auto: boolean?, -- game: opens by itself when the step starts
    wrongClick: string?, -- find (direct): gentle note when the click isn't a candidate
    zoneRadius: number?, -- find: the search zone's radius in metres
    question: string?, -- choose
    choices: { Choice }?,
    stop: string?, -- check: the stop's name
    findings: { string }?, -- check: what could be wrong here
    problem: string?, -- check: the finding that is true here (nil: normal)
    clue: string?, -- check: what gave the problem away
}
type Abnormality = {
    key: string, stops: { string }, finding: string, leak: string?, clue: string,
    respond: { Choice },
}
type Scenario = {
    id: string, title: string, blurb: string, locked: boolean?,
    setup: (run: any) -> { Step },
    apply: ((run: any, s: Art.Telemetry) -> ())?,
    readings: ((run: any, id: string, out: { Reading }) -> ())?,
}

local CATS = {
    { key = "ident", label = "Finding equipment" },
    { key = "inspect", label = "Inspection" },
    { key = "fault", label = "Spotting faults" },
    { key = "safety", label = "Safe decisions" },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local seed = math.floor((os.clock() * 1000003) % 2147483646) + 1
local ROUND = 1 -- which round the menu plays: 2 once every exercise of round 1 is done
local function rand(n: number): number
    seed = (seed * 16807) % 2147483647
    return seed % n + 1
end

local function shuffle(t: { any }): { any }
    for i = #t, 2, -1 do
        local j = rand(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- Retags CH-1's ids and names for another chiller ("panel:CH1-CP" -> "panel:CH2-CP").
local function chTag(x: string, n: number): string
    if n == 1 then return x end
    local out = string.gsub(x, "CH%-1", "CH-" .. n)
    out = string.gsub(out, "CH1%-", "CH" .. n .. "-")
    return out
end

local function chTags(list: { string }, n: number): { string }
    local out = {}
    for i, x in list do out[i] = chTag(x, n) end
    return out
end

local function has(list: { string }?, v: string): boolean
    if list == nil then return false end
    for _, x in list do
        if x == v then return true end
    end
    return false
end

local function title(id: string): string
    local e = Training[id]
    return if e ~= nil then e.title else id
end

-- "CH-1", "CHWP-2"... from a title, or the whole title.
local function short(id: string): string
    local t = title(id)
    if #t <= 26 then return t end
    return string.match(t, "^(%u+%-%d+)") or t
end

local function wander(t: number, k: number): number
    return math.sin(t * 0.13 + k) * 0.6 + math.sin(t * 0.41 + k * 2.1) * 0.4
end

local function kpa(v: number): string
    return string.format("%d kPa  (%d psi)", math.round(v), math.round(v * 0.145))
end

-- Replaces a reading's value by label, or adds the reading.
local function setReading(out: { Reading }, label: string, value: string)
    for _, r in out do
        if r.label == label then r.value = value; return end
    end
    table.insert(out, { label = label, value = value })
end

local function baseId(id: string): string
    -- A leak's falling drop selects the leak itself.
    if string.sub(id, 1, 5) == "leak:" then return string.sub(id, 1, 7) end
    return id
end

local function isValve(id: string): boolean return string.sub(id, 1, 6) == "valve:" end
local function isLeak(id: string): boolean return string.sub(id, 1, 5) == "leak:" end
local function notLeak(id: string): boolean return not isLeak(id) end

-- ---------------------------------------------------------------------------
-- 1. Inspection round: six stops in order, one simulated problem among them
-- ---------------------------------------------------------------------------

type Stop = { key: string, name: string, objective: string, targets: { string }, findings: { string }, detail: string? }
local STOPS: { Stop } = {
    { key = "panel", name = "CH-1 control panel", objective = "Go to CH-1's control panel", targets = { "panel:CH1-CP" },
        findings = { "Leaving chilled water above setpoint", "Chiller tripped on an alarm", "Screen blank" } },
    { key = "chwgauges", name = "chilled water gauges", objective = "Read CH-1's two chilled water gauges", targets = { "gauge:CH1-CHWS", "gauge:CH1-CHWR" },
        findings = { "Leaving chilled water above setpoint", "A gauge needle is stuck", "Pressure out of range" } },
    { key = "cwgauges", name = "condenser water gauges", objective = "Read CH-1's two condenser water gauges", targets = { "gauge:CH1-CWS", "gauge:CH1-CWR" },
        findings = { "Condenser water above its 85 °F design", "A gauge needle is stuck", "Pressure out of range" } },
    { key = "pumps", name = "chilled water pumps", objective = "Check both chilled water pumps", targets = { "pump:CHWP-1", "pump:CHWP-2" },
        findings = { "Water leaking at a pump seal", "The duty pump is stopped", "Loud vibration" } },
    { key = "svalves", name = "pump suction valves", objective = "Check both CHW pump suction valves are open", targets = { "valve:CHWP-1-SV", "valve:CHWP-2-SV" },
        findings = { "CHWP-2 suction valve closed", "CHWP-1 suction valve closed", "Valve packing leaking" } },
    { key = "monitor", name = "refrigerant monitor", objective = "Check the refrigerant leak monitor", targets = { "monitor:RLM-1" },
        findings = { "Refrigerant reading above normal", "Screen blank", "Alarm horn sounding" } },
    { key = "hpvents", name = "header air vents", objective = "Climb to the walkway: check the header air vents", targets = { "vent:HP" },
        detail = "Take the stair at the far end of the chiller hall up to the walkway, then walk onto the hall bridge. The vents rise beside it.",
        findings = { "An air vent is spitting water", "A vent's isolating valve is shut", "Header pressure out of range" } },
}

local ABNORMALITIES: { Abnormality } = {
    {
        key = "airvent", stops = { "hpvents" }, finding = "An air vent is spitting water",
        clue = "The CHWR high-point vent is spitting water: its float is stuck, so water escapes with the air.",
        respond = {
            { label = "Report it so the vent is replaced; mark the wet floor below.", correct = true,
                feedback = "A stuck vent keeps leaking. It is changed with its isolating valve shut, under a work order." },
            { label = "Shut its isolating valve and leave it.", correct = false,
                feedback = "That stops the drip but leaves the header with no way to vent air. Report it so it is fixed properly." },
            { label = "Tap the vent until it stops.", correct = false, unsafe = true,
                feedback = "Striking fittings on a pressurized header can crack them. Report it instead." },
        },
    },
    {
        key = "standby", stops = { "svalves" }, finding = "CHWP-2 suction valve closed",
        clue = "CHWP-2's suction valve reads CLOSED, so the standby pump can't take over.",
        respond = {
            { label = "Report it. It's reopened only under the site procedure.", correct = true,
                feedback = "Someone may have closed it on purpose for work on CHWP-2. The supervisor needs to know the plant has no standby pump." },
            { label = "Open it yourself right away.", correct = false, unsafe = true,
                feedback = "If CHWP-2 is opened up for maintenance, opening its valve can flood it and hurt the person working on it." },
            { label = "Leave it: the duty pump is fine.", correct = false,
                feedback = "With no standby, one failure of CHWP-1 stops chilled water to the data hall." },
        },
    },
    {
        key = "lchw", stops = { "panel", "chwgauges" }, finding = "Leaving chilled water above setpoint",
        clue = "Leaving chilled water reads about 47.8 °F against a 44.0 °F setpoint.",
        respond = {
            { label = "Report it and keep watching the trend.", correct = true,
                feedback = "The control room compares the data hall's conditions and decides the plant's response." },
            { label = "Lower the setpoint to 40 °F.", correct = false, unsafe = true,
                feedback = "An unauthorized change: it doesn't fix the cause and can trip the chiller." },
            { label = "Ignore it: it's only a few degrees.", correct = false,
                feedback = "A few degrees at the chiller can be the start of the data hall overheating." },
        },
    },
    {
        key = "leak", leak = "L1", stops = { "pumps" }, finding = "Water leaking at a pump seal",
        clue = "Water drips from CHWP-1's shaft seal and pools on the floor.",
        respond = {
            { label = "Report it, keep people clear, mark the wet floor.", correct = true,
                feedback = "The seal is repaired later with the pump isolated and locked out, after the standby takes over." },
            { label = "Tighten the seal while it runs.", correct = false, unsafe = true,
                feedback = "A rotating shaft under pressure can catch clothing and spray water." },
            { label = "Mop it up and carry on.", correct = false,
                feedback = "The leak keeps going and gets worse. It must be reported so a repair is planned." },
        },
    },
    {
        key = "ppm", stops = { "monitor" }, finding = "Refrigerant reading above normal",
        clue = "The monitor reads about 85 ppm; normal is about 2 ppm.",
        respond = {
            { label = "Report it now; leave if it keeps rising.", correct = true,
                feedback = "Trained staff find the source with proper detectors and breathing protection." },
            { label = "Stay and search for the leak by smell.", correct = false, unsafe = true,
                feedback = "Refrigerant is heavier than air, displaces oxygen near the floor and often can't be smelled." },
            { label = "Silence the monitor.", correct = false, unsafe = true,
                feedback = "A warning is the early sign of a leak. Never silence it without finding the cause." },
        },
    },
    {
        key = "ecw", stops = { "cwgauges" }, finding = "Condenser water above its 85 °F design",
        clue = "Condenser water enters CH-1 at about 91 °F against its 85 °F design.",
        respond = {
            { label = "Report it so the cooling tower is checked.", correct = true,
                feedback = "Warm condenser water costs capacity; the tower is checked from the BAS or by tower staff." },
            { label = "Throttle the condenser water valve.", correct = false, unsafe = true,
                feedback = "Less condenser flow raises the pressure further and can trip the chiller." },
            { label = "Ignore it: the chiller still runs.", correct = false,
                feedback = "On a hot day this becomes a capacity loss or a high-pressure trip." },
        },
    },
}

-- What each inspection stop shows: gauges with a normal band, or a status line.
local function stopReadings(key: string, abn: string): { any }
    local function gauge(label: string, value: number, fmt: string, unit: string, lo: number, hi: number, mn: number, mx: number): any
        return { label = label, value = value, fmt = fmt, unit = unit, lo = lo, hi = hi, min = mn, max = mx }
    end
    if key == "panel" then
        local v = if abn == "lchw" then 47.8 else 44.1
        return { gauge("Leaving chilled water", v, string.format("%.1f", v), "°F", 42, 46, 38, 52), { label = "Chiller status", text = "RUNNING" },
            gauge("Load", 72, "72", "%", 20, 100, 0, 100), { label = "Alarms", text = "None" } }
    elseif key == "chwgauges" then
        local v = if abn == "lchw" then 47.8 else 44.1
        return { gauge("CHW supply (leaving)", v, string.format("%.1f", v), "°F", 42, 46, 38, 52), gauge("CHW return (entering)", 54.4, "54.4", "°F", 50, 58, 44, 64),
            gauge("CHW supply pressure", 410, "410", "kPa", 350, 480, 200, 600), gauge("CHW return pressure", 300, "300", "kPa", 250, 380, 100, 500) }
    elseif key == "cwgauges" then
        local e = if abn == "ecw" then 91.2 else 84.5
        local l = e + 9.8
        return { gauge("CW entering CH-1", e, string.format("%.1f", e), "°F", 78, 86, 70, 100), gauge("CW leaving CH-1", l, string.format("%.1f", l), "°F", 88, 97, 80, 106),
            gauge("CW supply pressure", 330, "330", "kPa", 280, 400, 150, 500), gauge("CW return pressure", 240, "240", "kPa", 200, 320, 100, 400) }
    elseif key == "pumps" then
        return { gauge("CHWP-1 speed", 48.5, "48.5", "Hz", 30, 60, 0, 60), { label = "CHWP-1 shaft seal", text = if abn == "leak" then "DRIPPING, puddle below" else "Dry" },
            gauge("CHWP-2 speed", 0, "0.0", "Hz", 0, 0.1, 0, 60), { label = "CHWP-2", text = "Standby, ready" } }
    elseif key == "svalves" then
        return { { label = "CHWP-1 suction valve", text = "OPEN" }, { label = "CHWP-2 suction valve", text = if abn == "standby" then "CLOSED" else "OPEN" },
            { label = "Valve packing", text = "Dry" }, { label = "Position indicators", text = "Readable" } }
    elseif key == "hpvents" then
        return { { label = "CHWS vent", text = "Dry" }, { label = "CHWR vent", text = if abn == "airvent" then "SPITTING WATER" else "Dry" },
            { label = "CWS and CWR vents", text = "Dry" }, gauge("Header pressure", 410, "410", "kPa", 350, 480, 200, 600) }
    else
        local v = if abn == "ppm" then 85 else 2
        return { gauge("Refrigerant in air", v, tostring(v), "ppm", 0, 25, 0, 100), { label = "Monitor status", text = "ON, no fault" },
            { label = "Alarm setpoint", text = "300 ppm" }, { label = "Last calibration", text = "In date" } }
    end
end

local function routine(run: any): { Step }
    local abn = ABNORMALITIES[rand(#ABNORMALITIES)]
    -- Round 2 hides a second problem at a different stop.
    local abn2: Abnormality? = nil
    if ROUND >= 2 then
        repeat
            abn2 = ABNORMALITIES[rand(#ABNORMALITIES)]
            local clash = abn2 == abn
            for _, st in (abn2 :: Abnormality).stops do if has(abn.stops, st) then clash = true end end
        until not clash
    end
    run.abn = abn
    run.abn2 = abn2
    local ch = rand(2) -- the round's chiller stops are on CH-1 or CH-2
    run.chiller = ch
    run.leak = abn.leak or (if abn2 ~= nil then abn2.leak else nil)
    if abn.key == "standby" or (abn2 ~= nil and abn2.key == "standby") then run.valves = { ["valve:CHWP-2-SV"] = false } end
    local steps: { Step } = {
        { kind = "goto", objective = "Locate the main chiller, CH-1", cat = "ident", points = 1,
            targets = { "chiller:CH-1" }, success = "Found CH-1, the centrifugal chiller that cools the data hall's water." },
    }
    for _, stop in STOPS do
        local which = abn
        if abn2 ~= nil and has((abn2 :: Abnormality).stops, stop.key) then which = abn2 :: Abnormality end
        local bad = has(which.stops, stop.key)
        local abnHere = which
        table.insert(steps, {
            kind = "game", game = "spot", objective = chTag(stop.objective, ch), cat = "inspect", points = 3,
            targets = chTags(stop.targets, ch),
            detail = stop.detail or "Walk up to it (glowing) and click it: read it fast.",
            ctx = {
                name = chTag(stop.name, ch), chiller = ch, bad = bad, findings = stop.findings, problem = if bad then abnHere.finding else nil,
                clue = if bad then abnHere.clue else nil, readings = stopReadings(stop.key, abnHere.key),
                summary = if bad then abnHere.clue else "All normal at the " .. stop.name .. ".",
            },
        })
    end
    table.insert(steps, { kind = "choose", objective = "Decide what happens next", cat = "safety", points = 3,
        question = (if abn2 ~= nil then "You found two problems. The first: " else "You found: ") .. abn.clue .. " What do you do?", choices = shuffle(table.clone(abn.respond)) })
    return steps
end

local function routineApply(run: any, s: Art.Telemetry)
    local merged: any = {}
    for _, a in { run.abn, run.abn2 } do
    s.fx = nil
    local key = a.key
    if key == "lchw" then
        s.lchw = 47.8 + 0.2 * wander(s.t, 1)
        s.echw = s.lchw + 10.0 * s.load / 0.7
        s.fx = { tone = "warn", alarmText = "WARN  LCHW ABOVE SETPOINT" }
    elseif key == "ppm" then
        s.ppm = 85 + 6 * wander(s.t, 2)
        s.fx = { monitor = "WARNING" }
    elseif key == "ecw" then
        s.ecw = 91.0 + 0.4 * wander(s.t, 3)
        s.lcw = s.ecw + 9.5 * s.load / 0.7
    end
    if s.fx ~= nil then for key2, v in s.fx :: any do merged[key2] = v end end
    end
    merged.chiller = run.chiller -- the readings above belong to the round's chiller
    s.fx = merged
end

local function routineReadings(run: any, id: string, out: { Reading })
    for _, a in { run.abn, run.abn2 } do
        if a.key == "ppm" and id == "monitor:RLM-1" then setReading(out, "Status", "WARNING (above normal)") end
        if a.key == "lchw" and (id == chTag("panel:CH1-CP", run.chiller or 1) or id == chTag("chiller:CH-1", run.chiller or 1)) then setReading(out, "Alarm", "WARNING: LCHW HIGH") end
        if a.key == "standby" and id == "pump:CHWP-2" then setReading(out, "Status", "STANDBY") end
    end
end

-- ---------------------------------------------------------------------------
-- 2. Valve hunt: three valves, each in a search zone
-- ---------------------------------------------------------------------------


local function valveHunt(run: any): { Step }
    local ch = rand(3) -- the work order can be for any of the three chillers
    return {
        { kind = "game", game = "match", objective = "Match the valves to their jobs", cat = "ident", points = 3,
            targets = { "valve:CHWP-1-SV", "valve:CHWP-2-SV" }, detail = "Walk up to the pump suction valves (glowing) and click one." },
        { kind = "game", game = "isolate", ctx = { chiller = ch }, objective = chTag("Isolate CH-1 for a work order", ch), cat = "ident", points = 3,
            targets = { chTag("valve:CH1-CHWS-IV", ch), chTag("valve:CH1-CHWR-IV", ch), chTag("valve:CH1-CWS-IV", ch), chTag("valve:CH1-CWR-IV", ch) },
            detail = chTag("Walk up to CH-1's isolation valves (glowing) and click one.", ch) },
        { kind = "game", game = "balance", objective = "Balance the condenser water flow", cat = "ident", points = 3,
            targets = { "valve:CH1-CWS-BV" }, detail = "Walk up to CH-1's condenser water balancing valve (glowing) and click it." },
    }
end

-- ---------------------------------------------------------------------------
-- 3. Pump failure. "P-01" is chilled water pump CHWP-1 in this room.
-- ---------------------------------------------------------------------------

local function pumpFailure(run: any): { Step }
    -- Random fault: either duty pump can be the one that fails; every name swaps to match.
    local sw = rand(2) == 2
    run.swap = sw
    local function t(x: string): string return Games.swapPumps(x, sw) end
    local function id(x: string): string return t(x) end
    run.alarm = { text = if sw then "PUMP P-02 (CHWP-2): FAULT DETECTED" else "PUMP P-01 (CHWP-1): FAULT DETECTED", acked = false }
    local ctx = { swap = sw }
    return {
        { kind = "alarm", objective = "Silence the alarm", cat = "inspect", points = 1, targets = { "alarm:SILENCE" } },
        { kind = "game", game = "inspect", ctx = ctx, objective = t("Inspect pump CHWP-1"), cat = "inspect", points = 3, targets = { id("pump:CHWP-1") },
            detail = t("Walk up to CHWP-1 (glowing) and click it: check it with your tools.") },
        { kind = "game", game = "drive", ctx = ctx, objective = "Read the pump drives", cat = "inspect", points = 3, targets = { "elec:VFD" },
            detail = "Walk up to the drive cabinets on the left wall (glowing) and click them." },
        { kind = "game", game = "evidence", auto = true, objective = "Tell us what happened", cat = "fault", points = 3,
            ctx = {
                swap = sw, title = "GREAT JOB! Tell us what happened", question = "What happened to the chilled water pumps?",
                summary = "CHWP-1 tripped on overload and the standby CHWP-2 took over automatically.", -- swapped when drawn
                clues = {
                    { text = "Drive 1 shows fault F005: motor overload", relevant = true },
                    { text = "CHWP-1 is silent, its shaft still, its motor hot", relevant = true },
                    { text = "CHWP-2 started by itself (auto standby)", relevant = true },
                    { text = "The refrigerant monitor reads 2 ppm", relevant = false, why = "Refrigerant has nothing to do with the pumps." },
                    { text = "Condenser water is at 84 °F", relevant = false, why = "That's normal and on the other water circuit." },
                },
                choices = {
                    { label = "CHWP-1 tripped; standby CHWP-2 took over.", correct = true, feedback = "Case solved: the fault code, the dead pump and the auto start all point to it." },
                    { label = "False alarm: CHWP-1 is running.", correct = false, feedback = "Its drive shows a fault and the pump is silent: it isn't running." },
                    { label = "The chiller tripped.", correct = false, feedback = "Nothing points at the chiller: the clues are all about the pumps." },
                },
            } },
        { kind = "game", game = "lockout", ctx = ctx, objective = t("Lock out CHWP-1"), cat = "safety", points = 3, targets = { "elec:DS-PUMP" },
            detail = "Walk up to the pump disconnect switches (glowing) and click them to play." },
        { kind = "game", game = "lineup", ctx = ctx, objective = t("Isolate CHWP-1 for repair"), cat = "safety", points = 3, targets = { id("pump:CHWP-1") },
            detail = t("Walk up to CHWP-1 (glowing) and click it to open its valve line-up.") },
    }
end

local function pumpApply(run: any, s: Art.Telemetry)
    s.lchw = 44.3 + 0.25 * wander(s.t, 4)
    s.echw = s.lchw + 10.0 * s.load / 0.7
    s.fx = {
        tone = "warn", alarmText = "ALARM  CHWP-1 FAULT",
        drives = if run.swap then { [1] = { hz = s.hz1, state = "run" }, [2] = { hz = 0, state = "fault" } } else { [1] = { hz = 0, state = "fault" }, [2] = { hz = s.hz1, state = "run" } },
        gauges = if run.swap then { ["CHW Pump 1 Gauge Face"] = 420, ["CHW Pump 2 Gauge Face"] = 150 } else { ["CHW Pump 1 Gauge Face"] = 150, ["CHW Pump 2 Gauge Face"] = 420 },
    }
end

local function pumpReadings(run: any, id: string, out: { Reading })
    if run.swap then id = Games.swapPumps(id, true) end
    if id == "pump:CHWP-1" then
        setReading(out, "Status", "FAULT · TRIPPED")
        setReading(out, "Drive speed", "0.0 Hz"); setReading(out, "Motor speed", "0 rpm"); setReading(out, "Flow", "0 gpm")
        setReading(out, "Drive fault", "F005 MOTOR OVERLOAD")
    elseif id == "pump:CHWP-2" then
        setReading(out, "Status", "RUNNING (auto start)")
        setReading(out, "Drive speed", "52.0 Hz"); setReading(out, "Flow", "1040 gpm")
        setReading(out, "Discharge pressure", kpa(420))
    elseif id == "elec:VFD" then
        if run.swap then
            setReading(out, "CHWP-2 drive", "FAULT F005"); setReading(out, "CHWP-1 drive", "52.0 Hz (auto start)")
        else
            setReading(out, "CHWP-1 drive", "FAULT F005"); setReading(out, "CHWP-2 drive", "52.0 Hz (auto start)")
        end
    elseif id == "chiller:CH-1" or id == "panel:CH1-CP" then
        setReading(out, "Alarm", if run.swap then "CHWP-2 FAULT (plant alarm)" else "CHWP-1 FAULT (plant alarm)")
    end
end

-- ---------------------------------------------------------------------------
-- 4. Water leak
-- ---------------------------------------------------------------------------

type LeakSite = { source: string, accept: { string }, report: { Choice }, extra: string }
local LEAKS: { [string]: LeakSite } = {
    L1 = {
        source = "pump:CHWP-1", accept = { "pump:CHWP-1" }, extra = "",
        report = {
            { label = "Steady drip from CHWP-1's shaft seal; puddle 0.6 m.", correct = true,
                feedback = "Accurate: the equipment, where on it, how much, and that the pump is running." },
            { label = "A chilled water pipe burst near the pumps.", correct = false, feedback = "It's a drip from a pump seal, not a burst pipe." },
            { label = "Condenser water leaking from CWP-1.", correct = false, feedback = "Wrong pump: CHWP-1 is a chilled water pump." },
        },
    },
    L2 = {
        source = "valve:CH1-CHWR-IV", accept = { "valve:CH1-CHWR-IV", "pipe:CHWR" }, extra = " It's behind the guard rail: report it from the rail.",
        report = {
            { label = "Drip from CH-1's CHW return valve flange; puddle 0.7 m.", correct = true,
                feedback = "Accurate: the equipment, where on it, how much, and that the chiller is running." },
            { label = "The chiller is leaking refrigerant.", correct = false, feedback = "It's water from a pipe flange; the refrigerant monitor reads normal." },
            { label = "The condenser water supply valve is leaking.", correct = false, feedback = "Wrong valve: it's the chilled water return isolation valve." },
        },
    },
    L3 = {
        source = "pump:CWP-1", accept = { "pump:CWP-1" }, extra = " Condenser water is chemically treated: avoid skin contact.",
        report = {
            { label = "Steady drip from CWP-1's shaft seal; puddle 0.6 m.", correct = true,
                feedback = "Accurate: the equipment, where on it, how much, and that the pump is running." },
            { label = "Chilled water leaking from CHWP-1.", correct = false, feedback = "Wrong pump: CWP-1 is a condenser water pump." },
            { label = "The cooling tower is overflowing.", correct = false, feedback = "The water comes from a pump seal in this room." },
        },
    },
}

local function waterLeak(run: any): { Step }
    local keys = { "L1", "L2", "L3" }
    local k = keys[rand(3)]
    run.leak = k
    local site = LEAKS[k]
    return {
        { kind = "find", objective = "Find the water on the floor", cat = "ident", points = 2, direct = true,
            detail = "Walk into the yellow ring and look down at the floor. When you see the puddle, click it.",
            wrongClick = "Not that: look down. The water is a puddle on the floor inside the yellow ring.",
            targets = { "leak:" .. k }, accepts = isLeak, answer = "This is the leak", zoneRadius = 3.0,
            hint = "Walk along the pumps and around the chiller: water collects below the leak.",
            success = "Found it: an active drip and a puddle." .. site.extra },
        { kind = "game", game = "contain", auto = true, objective = "Contain the leak", cat = "safety", points = 3, targets = { "leak:" .. k } },
        { kind = "find", objective = "What's leaking? Click it", cat = "ident", points = 2, direct = true,
            detail = "Stand by the puddle and look straight up: drops fall from the leaking part. Click that part.",
            wrongClick = "That's the puddle. Look straight up from it and click the part the drops fall from.",
            targets = site.accept, accepts = notLeak, answer = "This is leaking", zoneRadius = 1.4,
            hint = "Look straight above the puddle.",
            success = title(site.source) .. " is leaking." },
        { kind = "choose", objective = "Report it", cat = "fault", points = 3,
            question = "Which report is accurate?", choices = shuffle(table.clone(site.report)) },
    }
end

-- ---------------------------------------------------------------------------
-- 5. High chilled water temperature. The evidence points to warm condenser
-- water (the cooling tower), which makes CH-1 limit its capacity.
-- ---------------------------------------------------------------------------

local function tempAlarm(run: any): { Step }
    -- The running chillers share the tower: either CH-1 or CH-2 is the one that trips into its limit.
    local n = rand(2)
    run.chiller = n
    local function t(x: string): string return chTag(x, n) end
    run.alarm = { text = t("CH-1: CHILLED WATER SUPPLY TEMPERATURE HIGH"), acked = false }
    return {
        { kind = "alarm", objective = "Silence the alarm", cat = "inspect", points = 1, targets = { "alarm:SILENCE" } },
        { kind = "goto", objective = t("Go to CH-1's control panel"), detail = "Follow the marker.", cat = "inspect", points = 1,
            targets = { t("panel:CH1-CP") }, success = "Leaving water 49.6 °F against a 44.0 °F setpoint. Capacity is limited." },
        { kind = "goto", objective = t("Read the four gauges at CH-1"), detail = "Click each marked gauge.", cat = "inspect", points = 2,
            targets = { t("gauge:CH1-CHWS"), t("gauge:CH1-CHWR"), t("gauge:CH1-CWS"), t("gauge:CH1-CWR") }, needAll = true,
            success = "Chilled water 49.6 / 58.2 °F. Condenser water enters at 93 °F (design 85 °F)." },
        { kind = "game", game = "evidence", auto = true, objective = "Find the cause", cat = "fault", points = 3,
            ctx = {
                title = "GREAT JOB! What's causing it?", question = "Why is the chilled water too warm?",
                summary = t("Warm condenser water from the cooling tower raises CH-1's pressure, so it limits its own capacity."),
                clues = {
                    { text = "Condenser water enters at 93 °F (design 85 °F)", relevant = true },
                    { text = "The panel shows a pressure LIMIT", relevant = true },
                    { text = "Both duty pumps are running normally", relevant = false, why = "It rules out a pump failure, but doesn't prove the tower is the cause." },
                    { text = "The refrigerant monitor reads 2 ppm", relevant = false, why = "It rules out a leak, but doesn't prove the tower is the cause." },
                },
                choices = {
                    { label = "The cooling tower isn't cooling the condenser water enough.", correct = true, feedback = "Case solved: hot condenser water plus a pressure limit means the tower can't keep up." },
                    { label = "A chilled water pump has failed.", correct = false, feedback = "Both duty pumps are running normally." },
                    { label = "The chiller is leaking refrigerant.", correct = false, feedback = "The monitor reads 2 ppm, which is normal." },
                },
            } },
        { kind = "game", game = "tower", ctx = { chiller = n }, objective = "Bring the condenser water back into range", cat = "fault", points = 3, targets = { t("panel:CH1-CP") },
            detail = t("Walk up to CH-1's control panel (glowing) and click it to open the plant controls.") },
        { kind = "choose", objective = "What do you do?", cat = "safety", points = 3,
            question = "Condenser water is back in range, on two tower cells.",
            choices = shuffle({
                { label = "Report it with the readings: cell 2 was offline and needs checking.", correct = true,
                    feedback = "The fix is at the tower, and the control room follows its high-temperature procedure." },
                { label = "Lower the setpoint to 40 °F.", correct = false, unsafe = true,
                    feedback = "Unauthorized, and it backfires: a colder setpoint raises the condenser pressure further." },
                { label = "Override the high-pressure limit.", correct = false, unsafe = true,
                    feedback = "Safety limits protect the machine and the people near it. Never override them." },
            }) },
    }
end

local function tempApply(run: any, s: Art.Telemetry)
    -- The rise happened just before the alarm (the trend shows it); it now holds near 49.6 °F.
    if not run.trendSet then
        run.trendSet = true
        for i = 1, #s.trend do s.trend[i] = 44.0 + 5.6 * math.clamp((i - 6) / (#s.trend - 16), 0, 1) end
    end
    s.load = 0.60 + 0.01 * wander(s.t, 5)
    s.lchw = 49.6 + 0.1 * wander(s.t, 6)
    s.echw = s.lchw + 8.6
    s.ecw = 93.2 + 0.3 * wander(s.t, 7)
    s.lcw = s.ecw + 9.5 * s.load / 0.7
    s.kw = 400 * s.load + 45
    s.amps = s.kw * 1.29
    s.fx = { chiller = run.chiller, tone = "bad", limit = "LIMIT", alarmText = string.format("ALARM  LCHW HIGH %.1f°F · COND PRESS LIMIT", s.lchw) }
end

local function tempReadings(run: any, id: string, out: { Reading })
    if id == chTag("chiller:CH-1", run.chiller or 1) or id == chTag("panel:CH1-CP", run.chiller or 1) then
        setReading(out, "Status", "RUNNING · LIMITED")
        setReading(out, "Limit active", "High condenser pressure")
        setReading(out, "Setpoint", "44.0 °F")
    end
end

-- ---------------------------------------------------------------------------
-- The scenarios, in menu order. Add new exercises here.
-- ---------------------------------------------------------------------------

-- The finale: faults one after another all night. Unlocked by gold in all five exercises.
local function nightShift(run: any): { Step }
    run.alarm = { text = "02:14  PUMP P-01 (CHWP-1): FAULT DETECTED", acked = false }
    run.leak = "L1"
    return {
        { kind = "alarm", objective = "02:14 · Silence the alarm", cat = "inspect", points = 1, targets = { "alarm:SILENCE" } },
        { kind = "game", game = "drive", ctx = {}, objective = "02:15 · Read the pump drives", cat = "inspect", points = 3, targets = { "elec:VFD" },
            detail = "Walk up to the drive cabinets (glowing) and click them." },
        { kind = "game", game = "lockout", ctx = {}, objective = "02:20 · Lock out CHWP-1", cat = "safety", points = 3, targets = { "elec:DS-PUMP" },
            detail = "Walk up to the pump disconnect switches (glowing) and click them." },
        { kind = "game", game = "contain", auto = true, objective = "03:05 · A seal lets go: contain the leak", cat = "safety", points = 3, targets = {} },
        { kind = "game", game = "spot", objective = "03:50 · Pumps gurgling: check the header air vents from the walkway", cat = "inspect", points = 3,
            targets = { "vent:HP" }, detail = "Up the stair at the far end of the hall, onto the hall bridge.",
            ctx = { name = "header air vents", bad = true, findings = { "An air vent is spitting water", "A vent's isolating valve is shut", "Header pressure out of range" },
                problem = "An air vent is spitting water", clue = "The CHWR high-point vent is spitting water: its float is stuck.",
                readings = stopReadings("hpvents", "airvent"), summary = "Found it: the CHWR vent is stuck open. Reported for replacement." } },
        { kind = "game", game = "tower", objective = "04:40 · Condenser water climbing: fix the tower", cat = "fault", points = 3, targets = { "panel:CH1-CP" },
            detail = "Walk up to CH-1's control panel (glowing) and click it." },
        { kind = "game", game = "isolate", ctx = { chiller = 3 }, objective = "05:30 · Hand over: isolate CH-3 for the day crew", cat = "ident", points = 3,
            targets = { "valve:CH3-CHWS-IV", "valve:CH3-CHWR-IV", "valve:CH3-CWS-IV", "valve:CH3-CWR-IV" },
            detail = "Walk down the chiller hall to CH-3's isolation valves (glowing) and click one." },
    }
end

local SCENARIOS: { Scenario } = {
    { id = "pump", title = "Pump Failure", blurb = "Inspect, diagnose, lock out, isolate. 5 games.", setup = pumpFailure, apply = pumpApply, readings = pumpReadings },
    { id = "leak", title = "Water Leak", blurb = "Find it and contain it before it reaches 480 V.", setup = waterLeak },
    { id = "valves", title = "Valve Hunt", blurb = "Match, isolate and balance valves. 3 games.", setup = valveHunt },
    { id = "temp", title = "Hot Chilled Water", blurb = "Crack the case, then fix the tower. 2 games.", setup = tempAlarm, apply = tempApply, readings = tempReadings },
    { id = "routine", title = "Inspection Round", blurb = "Seven quick checks, one up on the walkway; one hidden problem.", setup = routine, apply = routineApply, readings = routineReadings },
    { id = "night", title = "Night Shift", blurb = "The finale: six faults, one long night.", setup = nightShift, apply = pumpApply, readings = pumpReadings, locked = true },
}
Sim.SCENARIOS = SCENARIOS

-- Best result per scenario this session (percent).
local BEST: { [string]: number } = {}
-- What the page tells the scene (see Sim.sync): today's shift and the player's streak.
local SYNC = { dailyEx = "", dailySeed = 1, dailyDone = false, streak = 0, round2 = false }

-- The page's saved progress, as "best=pump:95,leak:80;daily=temp:12345:0;streak=3".
function Sim.sync(st: State, text: string)
    for key: string, val: string in string.gmatch(text, "(%w+)=([^;]*)") :: any do
        if key == "best" then
            for id: string, pct: string in string.gmatch(val, "(%w+):(%d+)") :: any do
                local n = tonumber(pct) or 0
                if BEST[id] == nil or n > BEST[id] then BEST[id] = n end
            end
        elseif key == "daily" then
            local ex, sd, done = string.match(val :: string, "(%w+):(%d+):(%d)")
            if ex ~= nil then SYNC.dailyEx, SYNC.dailySeed, SYNC.dailyDone = ex, tonumber(sd) or 1, done == "1" end
        elseif key == "round" then
            if val == "2" then
                if not SYNC.round2 then ROUND = 2 end
                SYNC.round2 = true
            end
        elseif key == "streak" then
            SYNC.streak = tonumber(val) or 0
        end
    end
    st.version += 1
end

function Sim.popReport(st: State): string?
    if #st.reports == 0 then return nil end
    return table.remove(st.reports, 1)
end

-- ---------------------------------------------------------------------------
-- State and engine
-- ---------------------------------------------------------------------------

export type State = {
    active: boolean,
    phase: string, -- "menu", "play", "results", "knowledge"
    scenario: Scenario?,
    run: any,
    steps: { Step },
    step: number,
    tries: number,
    stepSeen: { [string]: boolean },
    answered: Choice?,
    revealed: boolean, -- find: the exact marker is showing
    checkStage: string?, -- check: nil, "decide" or "finding"
    score: { [string]: { got: number, max: number } },
    points: number,
    streak: number,
    bestStreak: number,
    objectives: { { text: string, ok: boolean } },
    results: { [number]: boolean }, -- per step: done right or not
    notes: { string },
    feedback: { text: string, good: boolean }?,
    toasts: { Toast },
    explored: { [string]: boolean },
    newBest: boolean,
    version: number, -- bumps whenever the card or panel needs repainting
    game: Games.Game?, -- the open mini game, if any
    combo: number, -- inspection round: spot games right first time in a row
    lastSkipped: boolean, -- the previous step ran out of time
    reachT: number, -- seconds since this step's travel clock started
    reachLimit: number?, -- seconds allowed to reach the target (main.luau sets it from the distance)
    reachState: string, -- "off", "running", "made", "late"
    hard: boolean, -- hard mode: no markers or glow, double points
    hardPick: boolean, -- the menu's hard-mode toggle
    round: number, -- the round this exercise is played at
    unlockedRound: boolean, -- this result just unlocked round 2
    daily: boolean, -- today's shift (seeded by the date)
    bestCombo: number,
    reports: { string }, -- finished games and exercises, for the page (main.luau sends them)
}

function Sim.new(): State
    return {
        active = false, phase = "menu", scenario = nil, run = {}, steps = {}, step = 1, tries = 0,
        stepSeen = {}, answered = nil, revealed = false, checkStage = nil, score = {}, points = 0, streak = 0, bestStreak = 0,
        objectives = {}, results = {}, notes = {}, feedback = nil, toasts = {}, explored = {}, newBest = false, version = 0, game = nil, combo = 0, lastSkipped = false, reachT = 0, reachLimit = nil, reachState = "off", hard = false, hardPick = false, round = 1, unlockedRound = false, daily = false, bestCombo = 0, reports = {},
    }
end

local function touch(st: State) st.version += 1 end

local function toast(st: State, text: string, tone: string, points: number?)
    table.insert(st.toasts, { text = text, tone = tone, points = points or 0 })
end

-- Scores a finished step: points, streak and a toast.
local function award(st: State, cat: string, got: number, max: number, text: string?)
    local c = st.score[cat]
    if c == nil then c = { got = 0, max = 0 }; st.score[cat] = c end
    if st.hard then got, max = got * 2, max * 2 end
    c.got += got
    c.max += max
    st.points += got
    if got >= max and max > 0 then
        st.streak += 1
        st.bestStreak = math.max(st.bestStreak, st.streak)
        local msg = text or "Nice!"
        if st.streak >= 3 then msg = msg .. "  ·  " .. st.streak .. " in a row" end
        toast(st, msg, "good", got)
    elseif got > 0 then
        st.streak = 0
        toast(st, text or "Got there", "warn", got)
    else
        st.streak = 0
        toast(st, text or "Not quite", "bad", 0)
    end
end

local function objective(st: State, text: string, ok: boolean)
    table.insert(st.objectives, { text = text, ok = ok })
    st.results[st.step] = ok
end

local function current(st: State): Step?
    if st.phase ~= "play" then return nil end
    return st.steps[st.step]
end

local finish: (st: State) -> ()

-- Steps with a travel clock: walk to an exact target and click it.
local function timedStep(s: Step): boolean
    if s.targets == nil or #(s.targets :: { string }) == 0 then return false end
    return s.kind == "goto" or s.kind == "alarm" or s.kind == "check" or (s.kind == "game" and not s.auto)
end

-- How the travel clock shrinks as you advance (round 2, hard mode, Night Shift, later steps).
local function paceFactor(st: State): number
    local d = 1.0
    if st.round >= 2 then d *= 0.8 end
    if st.hard then d *= 0.85 end
    if st.scenario ~= nil and (st.scenario :: Scenario).id == "night" then d *= 0.85 end
    return d * math.max(0.6, 1 - 0.04 * (st.step - 1))
end

-- Less time the further you get: round 2, hard mode, the Night Shift, and each later game in an exercise.
local function setDifficulty(st: State)
    local d = 1.0
    if st.round >= 2 then d *= 0.8 end
    if st.hard then d *= 0.85 end
    if st.scenario ~= nil and (st.scenario :: Scenario).id == "night" then d *= 0.85 end
    d *= math.max(0.6, 1 - 0.04 * (st.step - 1))
    Games.difficulty = d
end

local function nextStep(st: State)
    st.step += 1
    st.tries = 0
    st.stepSeen = {}
    st.answered = nil
    st.revealed = false
    st.checkStage = nil
    st.game = nil
    st.reachT, st.reachLimit = 0, nil
    local skipped = st.lastSkipped
    st.lastSkipped = false
    local nxt = current(st)
    st.reachState = if nxt ~= nil and timedStep(nxt) then "running" else "off"
    if nxt == nil then
        finish(st)
    elseif nxt.kind == "game" and nxt.auto then
        setDifficulty(st)
        local ctx = nxt.ctx
        -- No "GREAT JOB!" straight after a step was skipped for time.
        if skipped and ctx ~= nil and type(ctx.title) == "string" then
            ctx = table.clone(ctx)
            ctx.title = (string.gsub(ctx.title, "^GREAT JOB! ", ""))
        end
        st.game = Games.new(nxt.game or "", ctx)
    end
    touch(st)
end

function Sim.begin(st: State)
    st.active = true
    st.phase = "menu"
    st.scenario = nil
    st.run = {}
    st.feedback = nil
    st.toasts = {}
    touch(st)
end

function Sim.stop(st: State)
    st.active = false
    st.game = nil
    st.phase = "menu"
    st.scenario = nil
    st.run = {}
    st.feedback = nil
    st.toasts = {}
    touch(st)
end

-- Opens a step's mini game; inspection stops carry the running combo.
local function openGame(st: State, s: Step): Games.Game
    setDifficulty(st)
    local ctx = s.ctx
    if s.game == "spot" and ctx ~= nil then ctx.combo = st.combo end
    return Games.new(s.game or "", ctx)
end

-- What changes in round 2, shown on the menu.
local ROUND2_BLURBS: { [string]: string } = {
    pump = "Tighter clocks; the line-up starts with a valve left shut.",
    leak = "The water spreads faster.",
    valves = "Seven valve types, a full isolation, a tighter flow band.",
    temp = "Two tower faults at once.",
    routine = "Seven-second checks; TWO hidden problems.",
    night = "The finale, round 2.",
}

-- Medals are kept per round: round 2's under "pump2" and so on.
local function bestKey(id: string, round: number): string
    return if round >= 2 then id .. "2" else id
end

-- Round 1 is done when every exercise, Night Shift included, has been finished once.
local function roundOneDone(): boolean
    for _, sc in SCENARIOS do
        if BEST[sc.id] == nil then return false end
    end
    return true
end

-- The exercise after the current one in menu order, wrapping round to the first.
local function nextScenario(st: State): Scenario?
    local cur = st.scenario
    if cur == nil then return nil end
    for i, sc in SCENARIOS do
        if sc == cur then
            local nx = SCENARIOS[i % #SCENARIOS + 1]
            if nx.locked then
                local allDone = true
                for _, sc in SCENARIOS do
                    if not sc.locked and BEST[bestKey(sc.id, ROUND)] == nil then allDone = false end
                end
                if not allDone then nx = SCENARIOS[1] end
            end
            return nx
        end
    end
    return nil
end

local function startScenario(st: State, sc: Scenario)
    seed = (seed + math.floor((os.clock() * 7919000) % 1000003)) % 2147483646 + 1 -- vary each run
    if st.daily then seed = SYNC.dailySeed end -- today's shift: the same faults for everyone today
    st.bestCombo = 0
    st.round = ROUND
    Games.round = ROUND
    st.scenario = sc
    st.run = {}
    st.score = {}
    st.points, st.streak, st.bestStreak = 0, 0, 0
    st.objectives = {}
    st.results = {}
    st.notes = {}
    st.feedback = nil
    st.toasts = {}
    st.newBest = false
    st.combo = 0
    st.steps = sc.setup(st.run)
    st.step = 0
    st.phase = "play"
    nextStep(st)
end

local function percent(st: State): number
    local got, max = 0, 0
    for _, c in st.score do got += c.got; max += c.max end
    return if max > 0 then math.round(got / max * 100) else 0
end

local function stars(pct: number): number
    return if pct >= 90 then 3 elseif pct >= 70 then 2 elseif pct >= 40 then 1 else 0
end
Sim.stars = function(st: State): number return stars(percent(st)) end

finish = function(st: State)
    st.phase = "results"
    local sc = st.scenario
    if sc ~= nil then
        local pct = percent(st)
        local key = bestKey(sc.id, st.round)
        local prev = BEST[key]
        st.newBest = prev ~= nil and pct > prev
        if prev == nil or pct > prev then BEST[key] = pct end
        st.unlockedRound = false
        if st.round == 1 and not SYNC.round2 and roundOneDone() then
            SYNC.round2, ROUND = true, 2
            st.unlockedRound = true
            table.insert(st.reports, '{"t":"round","n":2}')
        end
        table.insert(st.reports, string.format('{"t":"done","ex":"%s","round":%d,"pct":%d,"points":%d,"hard":%s,"daily":%s,"combo":%d}',
            sc.id, st.round, pct, st.points, tostring(st.hard), tostring(st.daily), st.bestCombo))
    end
    touch(st)
end

-- Marks a goto / check target as reached; returns whether the step's targets are all reached.
local function reach(st: State, s: Step, id: string): boolean
    if not has(s.targets, id) then return false end
    st.stepSeen[id] = true
    for _, t in s.targets or {} do
        if not st.stepSeen[t] and (s.needAll or false) then return false end
    end
    return true
end

local function seenCount(st: State, s: Step): number
    local n = 0
    for _, t in s.targets or {} do
        if st.stepSeen[t] then n += 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- The scenario card
-- ---------------------------------------------------------------------------

local LETTERS = { "A", "B", "C", "D", "E" }

-- The check stop's question and buttons, shared by the card and the inspect panel.
local function checkButtons(st: State, s: Step): (string, { Button })
    local buttons: { Button } = {}
    if st.checkStage == "finding" then
        for i, f in s.findings or {} do table.insert(buttons, { label = LETTERS[i] .. "|" .. f, action = "finding:" .. i, style = "abc" }) end
        table.insert(buttons, { label = "Back", action = "back", style = "quiet" })
        return "What's wrong?", buttons
    end
    table.insert(buttons, { label = "Looks normal", action = "normal", style = "primary" })
    table.insert(buttons, { label = "Something's wrong", action = "problem", style = "choice" })
    return "Is everything normal at the " .. (s.stop or "stop") .. "?", buttons
end

function Sim.card(st: State): Card
    local lines: { Line } = {}
    local buttons: { Button } = {}
    if st.phase == "menu" then
        if SYNC.dailyEx ~= "" then
            local title = ""
            for _, sc in SCENARIOS do if sc.id == SYNC.dailyEx then title = sc.title end end
            local streak = if SYNC.streak > 0 then string.format("  ·  %d-day streak", SYNC.streak) else ""
            table.insert(buttons, { label = if SYNC.dailyDone
                then "TODAY'S SHIFT DONE  ·  " .. title .. streak .. "  ·  Play again for practice"
                else "TODAY'S SHIFT: " .. title .. streak .. "  >", action = "daily", style = "go" })
        end
        local allDone = true
        for _, sc in SCENARIOS do
            if not sc.locked and BEST[bestKey(sc.id, ROUND)] == nil then allDone = false end
        end
        for i, sc in SCENARIOS do
            if sc.locked and not allDone then
                table.insert(buttons, { label = "LOCKED: " .. sc.title .. " — Finish all five exercises to unlock the finale.", action = "locked", style = "choice" })
                continue
            end
            local best = BEST[bestKey(sc.id, ROUND)]
            local medal = if best == nil then "" elseif best >= 90 then "  ·  GOLD" elseif best >= 70 then "  ·  SILVER" elseif best >= 40 then "  ·  BRONZE" else ""
            local hardOk = st.hardPick and best ~= nil and best >= 90
            local pre = if hardOk then "HARD: " else ""
            local blurb = if ROUND >= 2 then (ROUND2_BLURBS[sc.id] or sc.blurb) else sc.blurb
            table.insert(buttons, { label = pre .. sc.title .. medal .. " — " .. blurb, action = (if hardOk then "hard:" else "start:") .. i, style = "choice" })
        end
        local golds = 0
        for _, sc in SCENARIOS do if (BEST[bestKey(sc.id, ROUND)] or 0) >= 90 then golds += 1 end end
        if golds > 0 then
            table.insert(buttons, { label = if st.hardPick then "Hard mode ON: no markers, double points (gold exercises)" else string.format("Hard mode: unlocked for %d gold exercise%s", golds, if golds == 1 then "" else "s"), action = "hardpick", style = "hint" })
        end
        table.insert(buttons, { label = "Explore freely — Click any equipment to learn about it.", action = "knowledge", style = "choice" })
        table.insert(buttons, { label = "End simulation", action = "end", style = "quiet" })
        if SYNC.round2 then
            table.insert(buttons, { label = if ROUND == 2 then "Back to Round 1 (practice)" else "Go to Round 2 >", action = "round", style = "quiet" })
        end
        return { title = if ROUND == 2 then "Technician Training · Round 2" else "Technician Training", sub = if ROUND == 2 then "ROUND 2 · HARDER FAULTS" else "SIMULATION", lines = lines, buttons = buttons }
    elseif st.phase == "knowledge" then
        local n = 0
        for _ in st.explored do n += 1 end
        table.insert(lines, { kind = "objective", text = "Click any equipment" })
        table.insert(lines, { text = "Its panel shows what it does, common issues, what technicians check and the safety notes.", tone = "muted" })
        table.insert(lines, { text = string.format("Explored: %d", n), tone = "accent" })
        table.insert(buttons, { label = "Back to exercises", action = "menu", style = "primary" })
        table.insert(buttons, { label = "End simulation", action = "end", style = "quiet" })
        return { title = "Explore Freely", sub = "SIMULATION", lines = lines, buttons = buttons }
    elseif st.phase == "results" then
        local pct = percent(st)
        local n = stars(pct)
        table.insert(lines, { kind = "stars", text = tostring(n) })
        local verdict = if n == 3 then "Excellent work!" elseif n == 2 then "Good job!" elseif n == 1 then "Getting there." else "Keep practicing."
        table.insert(lines, { kind = "objective", text = verdict })
        table.insert(lines, { text = string.format("%d points · %d%%", st.points, pct) .. (if st.bestStreak >= 2 then string.format(" · best streak %d", st.bestStreak) else ""), tone = "muted" })
        if st.newBest then table.insert(lines, { text = "New personal best!", tone = "accent" }) end
        table.insert(lines, { kind = "rule", text = "" })
        for _, cat in CATS do
            local c = st.score[cat.key]
            if c ~= nil and c.max > 0 then
                table.insert(lines, { kind = "score", text = cat.label .. "|" .. string.format("%d / %d", c.got, c.max) })
            end
        end
        local missed = {}
        for _, o in st.objectives do
            if not o.ok then table.insert(missed, o.text) end
        end
        if #st.notes > 0 then
            table.insert(lines, { kind = "rule", text = "" })
            table.insert(lines, { kind = "head", text = "WORTH REMEMBERING" })
            for _, nt in st.notes do table.insert(lines, { kind = "check", text = nt, tone = "bad" }) end
        end
        if st.unlockedRound then
            table.insert(lines, 1, { kind = "cheer", text = "ROUND 2 UNLOCKED! Every exercise again, with harder faults." })
            table.insert(buttons, { label = "Start Round 2: " .. SCENARIOS[1].title .. "  >", action = "round2", style = "go" })
        else
            local nextSc = nextScenario(st)
            if nextSc ~= nil then table.insert(buttons, { label = "Next Exercise: " .. nextSc.title .. "  >", action = "next", style = "go" }) end
        end
        table.insert(buttons, { label = "Play again", action = "retry", style = "primary" })
        table.insert(buttons, { label = "Other exercises", action = "menu", style = "choice" })
        table.insert(buttons, { label = "End simulation", action = "end", style = "quiet" })
        return { title = (if st.scenario ~= nil then st.scenario.title else "") .. " complete", sub = "SIMULATED TRAINING RESULT", lines = lines, buttons = buttons }
    end
    -- Playing
    local sc = st.scenario :: Scenario
    local s = current(st)
    table.insert(lines, { kind = "progress", text = string.format("%d|%d|%d", st.step, #st.steps, st.points) })
    if sc.id == "routine" then
        -- The round's checklist: done items ticked, the current one highlighted.
        table.insert(lines, { kind = "head", text = "CHECKLIST" })
        for i, stp in st.steps do
            local tone = if i < st.step then (if st.results[i] == false then "bad" else "good") elseif i == st.step then "accent" else "muted"
            table.insert(lines, { kind = "check", text = stp.objective, tone = tone })
        end
        table.insert(lines, { kind = "rule", text = "" })
    end
    -- A quiz right after a finished task opens with a cheer.
    local prev = st.steps[st.step - 1]
    if s ~= nil and s.kind == "choose" and st.answered == nil and prev ~= nil and prev.kind ~= "choose" then
        table.insert(lines, { kind = "cheer", text = "GREAT JOB, TELL US WHAT HAPPENED!" })
    end
    if st.feedback ~= nil then
        table.insert(lines, { text = st.feedback.text, tone = if st.feedback.good then "good" else "bad" })
    end
    if s ~= nil then
        if sc.id ~= "routine" then table.insert(lines, { kind = "objective", text = s.objective }) end
        if st.reachState == "running" and st.reachLimit ~= nil then
            local left = (st.reachLimit :: number) - st.reachT
            table.insert(lines, { text = if left > 0 then string.format("Get there in %d:%02d for a +2 speed bonus", math.floor(left / 60), math.ceil(left) % 60)
                else "Too slow for the bonus: keep going", tone = if left > 5 then "warn" else "bad" })
        elseif st.reachState == "made" then
            table.insert(lines, { text = "Made it in time: +2 speed bonus", tone = "good" })
        end
        if s.kind == "alarm" then
            table.insert(lines, { text = st.run.alarm.text, tone = "bad" })
            table.insert(lines, { text = "Find the red PLANT ALARM SILENCE switch by the door (it's glowing red). Walk up to it and press it.", tone = "accent" })
        elseif s.kind == "game" then
            table.insert(lines, { text = s.detail or (if s.auto then "Solve it in the mini game." else "It's glowing. Walk up to it and click it."), tone = "accent" })
            local reached = false
            for _, id in s.targets or {} do if st.stepSeen[id] then reached = true end end
            if reached or s.auto then table.insert(buttons, { label = "Play the mini game", action = "game", style = "go" }) end
        elseif s.kind == "goto" or (s.kind == "check" and st.checkStage == nil) then
            local targets = s.targets or {}
            if #targets > 1 then
                table.insert(lines, { text = string.format("Walk up to each glowing item and click it · %d of %d done", seenCount(st, s), #targets), tone = "accent" })
            else
                table.insert(lines, { text = "It's glowing. Walk up to it and click it.", tone = "accent" })
            end
        elseif s.kind == "check" then
            local q, bs = checkButtons(st, s)
            table.insert(lines, { text = q, tone = "accent" })
            for _, b in bs do table.insert(buttons, b) end
        elseif s.kind == "find" then
            table.insert(lines, { text = s.detail or "Search the yellow zone.", tone = "accent" })
            if st.tries > 0 and s.hint ~= nil then table.insert(lines, { text = "Hint: " .. s.hint, tone = "warn" }) end
            if not st.revealed then
                table.insert(buttons, { label = "Show me where (fewer points)", action = "reveal", style = "hint" })
            end
        elseif s.kind == "choose" then
            if st.answered == nil then
                table.insert(lines, { text = s.question or "", tone = "muted" })
                for i, c in s.choices or {} do
                    table.insert(buttons, { label = LETTERS[i] .. "|" .. c.label, action = "choose:" .. i, style = "abc" })
                end
            else
                local a: Choice = st.answered :: any
                table.insert(lines, { text = (if a.correct then "Correct! " elseif a.unsafe then "Unsafe. " else "Not quite. ") .. a.feedback, tone = if a.correct then "good" else "bad" })
                if not a.correct then
                    for _, c in s.choices or {} do
                        if c.correct then table.insert(lines, { text = "Best answer: " .. c.label, tone = "muted" }) end
                    end
                end
                table.insert(buttons, { label = if st.step < #st.steps then "Next" else "See results", action = "continue", style = "primary" })
            end
        end
    end
    table.insert(buttons, { label = "Quit exercise", action = "menu", style = "quiet" })
    return { title = sc.title, sub = "SIMULATION", lines = lines, buttons = buttons }
end

-- Answers a check stop (from the card or the panel).
local function checkAction(st: State, s: Step, action: string): boolean
    if st.checkStage == nil then return false end
    local verdict: string? = nil
    if action == "normal" then
        verdict = "normal"
    elseif action == "problem" then
        st.checkStage = "finding"
    elseif action == "back" then
        st.checkStage = "decide"
    elseif string.sub(action, 1, 8) == "finding:" then
        local findings: { string } = s.findings or {}
        verdict = findings[tonumber(string.sub(action, 9)) or 0]
    else
        return false
    end
    if verdict ~= nil then
        local pts = s.points or 1
        local right = if s.problem == nil then verdict == "normal" else verdict == s.problem
        local label = "Check the " .. (s.stop or "stop")
        objective(st, label, right)
        if right then
            award(st, s.cat or "inspect", pts, pts, if s.problem ~= nil then "Problem spotted!" else "All normal here")
            st.feedback = { text = if s.problem ~= nil then "Spotted: " .. (s.clue or s.problem) else "The " .. (s.stop or "stop") .. " checks out.", good = true }
        else
            award(st, s.cat or "inspect", 0, pts, "Missed")
            local text = if s.problem ~= nil then "There was a problem here. " .. (s.clue or s.problem) else "This stop was normal; the problem is elsewhere."
            st.feedback = { text = text, good = false }
            table.insert(st.notes, text)
        end
        nextStep(st)
    end
    return true
end

-- The travel clock. main.luau gives it a limit once (from your distance to the target) and ticks it.
function Sim.reachClock(st: State): (string, number, number?)
    return st.reachState, st.reachT, st.reachLimit
end

function Sim.stepTargets(st: State): { string }?
    local s = current(st)
    if s == nil or st.reachState ~= "running" then return nil end
    return s.targets
end

function Sim.setReachLimit(st: State, walkSeconds: number)
    if st.reachState ~= "running" or st.reachLimit ~= nil then return end
    st.reachLimit = math.max(10, math.round((walkSeconds * 1.2 + 8) * paceFactor(st)))
    touch(st)
end

local function reached(st: State)
    if st.reachState ~= "running" then return end
    local made = st.reachLimit == nil or st.reachT <= (st.reachLimit :: number)
    st.reachState = if made then "made" else "late"
    if made then
        award(st, "speed", 2, 2, string.format("Made it in %d s!", math.round(st.reachT)))
    else
        award(st, "speed", 0, 2, "Got there, but too slow")
    end
    touch(st)
end

function Sim.tickReach(st: State, dt: number)
    if not st.active or st.phase ~= "play" or st.reachState ~= "running" or st.reachLimit == nil then return end
    local s = current(st)
    if s == nil then return end
    -- Reaching it: the step's target clicked (a game opened, a stop checked, a target seen).
    local hit = st.game ~= nil or st.checkStage ~= nil
    for _, id in s.targets or {} do if st.stepSeen[id] then hit = true end end
    if hit then reached(st); return end
    local before = math.floor(st.reachT)
    st.reachT += dt
    if st.reachT > (st.reachLimit :: number) and before <= (st.reachLimit :: number) then
        toast(st, "Too slow! Keep going", "bad", 0)
    end
    if math.floor(st.reachT) ~= before then touch(st) end
end

-- The alarm step: pressing the silence switch stops the horn (the fault stays).
local function silence(st: State, s: Step)
    reached(st)
    st.run.alarm.acked = true
    award(st, s.cat or "inspect", s.points or 1, s.points or 1, "Alarm silenced")
    objective(st, s.objective, true)
    st.feedback = { text = "Alarm silenced. That stops the horn; it doesn't clear the fault.", good = true }
    nextStep(st)
end

function Sim.cardAction(st: State, action: string)
    local s = current(st)
    if action ~= "continue" then st.feedback = nil end
    if action == "end" then
        Sim.stop(st)
    elseif action == "menu" then
        Sim.begin(st)
    elseif action == "knowledge" then
        st.phase = "knowledge"
        st.scenario = nil
        st.run = {}
        touch(st)
    elseif action == "round2" then
        ROUND = 2
        st.daily, st.hard = false, false
        startScenario(st, SCENARIOS[1])
    elseif action == "next" then
        st.daily, st.hard = false, false
        local nextSc = nextScenario(st)
        if nextSc ~= nil then startScenario(st, nextSc) end
    elseif action == "retry" and st.scenario ~= nil then
        startScenario(st, st.scenario :: Scenario)
    elseif action == "round" then
        if SYNC.round2 then ROUND = if ROUND == 2 then 1 else 2 end
    elseif action == "hardpick" then
        st.hardPick = not st.hardPick
    elseif action == "daily" then
        for _, sc in SCENARIOS do
            if sc.id == SYNC.dailyEx then
                st.hard, st.daily = false, true
                startScenario(st, sc)
            end
        end
    elseif string.sub(action, 1, 6) == "start:" then
        local sc = SCENARIOS[tonumber(string.sub(action, 7)) or 1]
        st.daily = false
        st.hard = false
        if sc ~= nil then startScenario(st, sc) end
    elseif string.sub(action, 1, 5) == "hard:" then
        local sc = SCENARIOS[tonumber(string.sub(action, 6)) or 1]
        st.daily = false
        st.hard = true
        if sc ~= nil then startScenario(st, sc) end
    elseif action == "game" and s ~= nil and s.kind == "game" then
        st.game = openGame(st, s)
    elseif action == "ack" and s ~= nil and s.kind == "alarm" then
        silence(st, s)
    elseif action == "reveal" and s ~= nil and s.kind == "find" then
        st.revealed = true
    elseif string.sub(action, 1, 7) == "choose:" and s ~= nil and s.kind == "choose" and st.answered == nil then
        local choices: { Choice } = s.choices or {}
        local c = choices[tonumber(string.sub(action, 8)) or 0]
        if c ~= nil then
            st.answered = c
            local pts = s.points or 1
            award(st, s.cat or "fault", if c.correct then pts else 0, pts, if c.correct then "Correct!" elseif c.unsafe then "Unsafe choice" else "Not quite")
            objective(st, s.objective, c.correct)
            if not c.correct then table.insert(st.notes, s.objective .. " " .. c.feedback) end
        end
    elseif action == "continue" and s ~= nil and s.kind == "choose" then
        st.feedback = nil
        nextStep(st)
    elseif s ~= nil and s.kind == "check" then
        checkAction(st, s, action)
    end
    touch(st)
end

-- A find step's answer: the right object scores (less after a miss or a reveal); two misses reveal it.
local function answerFind(st: State, s: Step, id: string)
    if has(s.targets, id) then
        local pts = s.points or 1
        local got = if st.revealed then 0 elseif st.tries == 0 then pts else math.ceil(pts / 2)
        award(st, s.cat or "ident", got, pts, if got == pts then "Found it!" elseif got > 0 then "Found it" else "Found, with help")
        objective(st, s.objective, got > 0)
        st.feedback = { text = s.success or title(id), good = true }
        nextStep(st)
    else
        st.tries += 1
        local e = Training[id]
        local what = if e ~= nil then e.title .. "." else "something else."
        if st.tries >= 2 and not st.revealed then
            st.revealed = true
            st.feedback = { text = "Not this one: that's the " .. what .. " The marker now shows the answer.", good = false }
        else
            st.feedback = { text = "Not this one: that's the " .. what, good = false }
        end
        toast(st, "Try again", "bad", 0)
        if st.tries == 1 then table.insert(st.notes, s.objective .. ": " .. (s.hint or "")) end
    end
end

-- Selecting equipment while a scenario runs.
function Sim.onSelect(st: State, id: string, near: boolean?)
    if not st.active then return end
    id = baseId(id)
    if st.phase == "knowledge" then
        if not st.explored[id] then st.explored[id] = true; touch(st) end
        return
    end
    local s = current(st)
    if s == nil then return end
    if (s.kind == "goto" or s.kind == "alarm" or s.kind == "game" or (s.kind == "check" and st.checkStage == nil)) and has(s.targets, id) and (s.kind == "game" or not st.stepSeen[id]) and near == false then
        st.feedback = { text = "Too far away: walk up to it, then click it again.", good = false }
        toast(st, "Get closer", "warn", 0)
        touch(st)
        return
    end
    if s.kind == "find" and s.direct then
        local accepts = s.accepts
        if accepts == nil or accepts(id) then
            answerFind(st, s, id)
        else
            st.feedback = { text = s.wrongClick or "Not that one.", good = false }
        end
        touch(st)
        return
    end
    if s.kind == "game" and has(s.targets, id) then
        st.stepSeen[id] = true
        st.game = openGame(st, s)
        st.feedback = nil
    elseif s.kind == "alarm" and has(s.targets, id) then
        silence(st, s)
    elseif s.kind == "goto" and has(s.targets, id) and not st.stepSeen[id] then
        if reach(st, s, id) then
            reached(st)
            local pts = s.points or 1
            award(st, s.cat or "inspect", pts, pts, "Reached " .. short(id))
            objective(st, s.objective, true)
            st.feedback = { text = s.success or title(id), good = true }
            nextStep(st)
        else
            st.feedback = { text = "Checked " .. title(id) .. ".", good = true }
            touch(st)
        end
    elseif s.kind == "check" and st.checkStage == nil and has(s.targets, id) and not st.stepSeen[id] then
        if reach(st, s, id) then
            st.checkStage = "decide"
            st.feedback = nil
        else
            st.feedback = { text = "Checked " .. title(id) .. ". Now the other one.", good = true }
        end
        touch(st)
    end
end

-- The extra block in the inspect panel for this id, if the scenario wants one.
function Sim.panelExtra(st: State, id: string): Extra?
    if not st.active then return nil end
    id = baseId(id)
    local s = current(st)
    if s == nil then return nil end
    if s.kind == "find" and not s.direct then
        local accepts = s.accepts
        if accepts == nil or accepts(id) then
            return { heading = "YOUR ANSWER", lines = { { text = s.objective, tone = "muted" } }, buttons = { { label = s.answer or "Select", action = "answer", style = "primary" } } }
        end
    elseif s.kind == "check" and st.checkStage ~= nil and has(s.targets, id) then
        local q, bs = checkButtons(st, s)
        return { heading = "INSPECTION", lines = { { text = q, tone = "muted" } }, buttons = bs }
    end
    return nil
end

function Sim.panelAction(st: State, id: string, action: string)
    id = baseId(id)
    local s = current(st)
    if s == nil then return end
    if s.kind == "find" and action == "answer" then
        answerFind(st, s, id)
    elseif s.kind == "check" then
        checkAction(st, s, action)
    end
    touch(st)
end

-- Name to show instead of the real one while the trainee must identify it.
function Sim.conceal(st: State, id: string): string?
    local s = current(st)
    if s == nil then return nil end
    if s.kind == "find" and s.conceal and isValve(id) then return "Unidentified valve" end
    return nil
end

function Sim.knowledge(st: State): boolean
    return st.active and st.phase == "knowledge"
end

-- What the 3D guides point at: exact targets (with which are done), or a search zone.
function Sim.markers(st: State): Markers?
    local s = current(st)
    if s == nil then return nil end
    if st.hard then return nil end -- hard mode: you find your own way
    if s.kind == "alarm" then
        return { targets = s.targets or {}, done = st.stepSeen, zone = nil, zoneRadius = 0, red = true }
    elseif s.kind == "game" then
        -- Keeps glowing until the game is solved (closing it early isn't done).
        return { targets = s.targets or {}, done = {}, zone = nil, zoneRadius = 0 }
    elseif s.kind == "goto" or s.kind == "check" then
        return { targets = s.targets or {}, done = st.stepSeen, zone = nil, zoneRadius = 0 }
    elseif s.kind == "find" then
        local targets = s.targets or {}
        if st.revealed then return { targets = { targets[1] }, done = {}, zone = nil, zoneRadius = 0 } end
        return { targets = {}, done = {}, zone = targets[1], zoneRadius = s.zoneRadius or 2.5 }
    end
    return nil
end

-- The oldest toast not yet shown, if any.
function Sim.popToast(st: State): Toast?
    if #st.toasts == 0 then return nil end
    return table.remove(st.toasts, 1)
end

-- Plant effects of the running scenario.
function Sim.apply(st: State, s: Art.Telemetry)
    s.fx = nil
    local sc = st.scenario
    if not st.active or sc == nil or (st.phase ~= "play" and st.phase ~= "results") then return end
    local f = sc.apply
    if f ~= nil then f(st.run, s) end
end

function Sim.readings(st: State, id: string, out: { Reading })
    local sc = st.scenario
    if not st.active or sc == nil or st.phase == "menu" then return end
    local f = sc.readings
    if f ~= nil then f(st.run, id, out) end
end

-- The visible leak ("L1".."L3"), if any.
function Sim.leak(st: State): string?
    if not st.active or st.scenario == nil or st.phase == "menu" then return nil end
    return st.run.leak
end

-- Valve positions the scenario forces (true open, false closed).
function Sim.valves(st: State): { [string]: boolean }?
    if not st.active or st.scenario == nil or st.phase == "menu" then return nil end
    return st.run.valves
end

-- The alarm banner: its text and whether it has been acknowledged.
function Sim.alarm(st: State): (string?, boolean)
    if not st.active or st.scenario == nil or st.phase ~= "play" then return nil, false end
    local a = st.run.alarm
    if a == nil then return nil, false end
    return a.text, a.acked
end


-- The open mini game, if any.
function Sim.game(st: State): Games.Game?
    if not st.active or st.phase ~= "play" then return nil end
    return st.game
end

-- "Back to the room": the game closes and the step stays; clicking the target again reopens it.
function Sim.closeGame(st: State)
    st.game = nil
    touch(st)
end

-- TIME'S UP: try the same game again from the start.
function Sim.retryGame(st: State)
    local s = current(st)
    if s == nil or s.kind ~= "game" then return end
    st.game = openGame(st, s)
    touch(st)
end

-- TIME'S UP: move on with no points for this step.
function Sim.skipGame(st: State)
    local g = st.game
    local s = current(st)
    if g == nil or s == nil then return end
    award(st, s.cat or "safety", 0, s.points or 3, "Out of time")
    objective(st, s.objective, false)
    table.insert(st.notes, g.title .. ": ran out of time. " .. g.summary)
    st.lastSkipped = true
    st.feedback = { text = "Skipped: out of time. " .. Games.swapPumps(g.summary, g.ctx ~= nil and g.ctx.swap == true, if g.ctx ~= nil then g.ctx.chiller else nil), good = false }
    nextStep(st)
end

-- A solved game completes its step, scored by its stars.
function Sim.finishGame(st: State)
    local g = st.game
    local s = current(st)
    if g == nil or s == nil or not g.solved then return end
    if g.kind == "spot" then st.combo = if g.mistakes == 0 then st.combo + 1 else 0 end
    st.bestCombo = math.max(st.bestCombo, st.combo)
    table.insert(st.reports, string.format('{"t":"game","ex":"%s","round":%d,"game":"%s","stars":%d,"mistakes":%d,"secs":%d,"hard":%s}',
        if st.scenario ~= nil then (st.scenario :: Scenario).id else "", st.round, g.kind, g.stars, g.mistakes, math.floor(g.solvedAt), tostring(st.hard)))
    local title = Games.swapPumps(g.title, g.ctx ~= nil and g.ctx.swap == true, if g.ctx ~= nil then g.ctx.chiller else nil)
    award(st, s.cat or "safety", g.stars, s.points or 3, string.format("%s: %d star%s", title, g.stars, if g.stars == 1 then "" else "s"))
    if g.kind == "spot" and st.combo >= 2 then toast(st, string.format("Combo x%d!", st.combo), "good", 0) end
    if g.mistakes > 0 and g.kind ~= "spot" then table.insert(st.notes, g.title .. ": " .. g.summary) end
    objective(st, s.objective, g.stars >= 2)
    st.feedback = { text = Games.swapPumps(g.summary, g.ctx ~= nil and g.ctx.swap == true, if g.ctx ~= nil then g.ctx.chiller else nil), good = true }
    nextStep(st)
end

return Sim
