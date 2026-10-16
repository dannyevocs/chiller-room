-- Mini games: a full-screen view opened from a training step ("game" steps in
-- sim.luau). The trainee walks up to the glowing equipment, clicks it, and plays
-- a short puzzle about it; solving it completes the step, with 1-3 stars.
--
--   lockout  radio, drive, disconnect, lock & tag, start: one button each, done in the safe order
--   lineup   open and close valves on a schematic to isolate a pump and keep flow going
--   tower    bring condenser water into its band with the tower's fans and cells (it lags)
--   balance  turn a balancing valve's handwheel until the flow meter reads design flow
--   match    pair each valve type with the job it does
--   isolate  close exactly the valves that isolate one side of the chiller for a work order
--   spot     an inspection stop on the clock: call its readings normal or a problem, then name it
--   evidence pin the clues that prove a conclusion, then pick it (red herrings don't count)
--   contain  a spreading puddle: lay absorbent socks, sign the walkway and report it before it reaches 480 V
--
-- Each game has a gold target (shown with its clock); stars: 3 = gold, 2 = silver, 1 = bronze.
--   inspect  click a part of a pump, choose how to check it (look, temperature, listen), find the clues it failed
--   drive    work a drive's keypad to read its fault, the motor current and which pump took over
--
-- Coordinates are layout points inside a Games.W x Games.H panel; main.luau scales it
-- to fit, paints it every frame while open and passes clicks and drags back here.

local Art = require("art")
local UI = require("ui")

local Games = {}
Games.round = 1 -- set by sim.luau when an exercise starts; round 2 makes every game a little harder
Games.difficulty = 1 -- set by sim.luau per game: scales the time limit (lower = less time)

-- Seconds each game allows before TIME'S UP, at difficulty 1.
local TIME_LIMIT: { [string]: number } = {
    lockout = 60, lineup = 60, tower = 70, balance = 70, inspect = 75, drive = 75,
    match = 60, isolate = 60, spot = 20, evidence = 60, contain = 60,
}
Games.W = 820
Games.H = 540

export type Hit = { x: number, y: number, w: number, h: number, action: string }

export type Game = {
    kind: string,
    title: string,
    intro: string,
    t: number,
    tries: number,
    solved: boolean,
    solvedAt: number,
    stars: number,
    summary: string,
    message: string?,
    messageGood: boolean,
    limit: number, -- seconds allowed
    timedOut: boolean,
    -- lockout
    cards: { number },
    picked: number?,
    locked: { [number]: boolean },
    flash: { [number]: number },
    -- lockout puzzle
    lo: { [string]: boolean }, -- radio, stopped, off, locked, tagged
    holding: string?, -- "lock" or "tag" from the kit
    spark: number, -- when an arc flashed (opening the disconnect too early)
    -- lineup
    valves: { [string]: boolean }, -- true = open
    -- tower
    fan: number,
    cell2: boolean,
    temp: number,
    hold: number,
    flatOut: number,
    -- balance
    turns: number, -- handwheel turns open, 0-10
    flow: number, -- the meter (lags the valve)
    dragX: number,
    dragTurns: number,
    dragAngle: number, -- balance: the pointer's angle around the wheel at the last move
    wheelAngle: number, -- balance: where the wheel is drawn (follows the hand exactly)
    grabbed: boolean,
    -- inspect
    tool: string?,
    part: string?, -- the part being checked
    checked: { [string]: boolean },
    mistakes: number,
    -- match
    matched: { [string]: boolean },
    selValve: string?,
    jobOrder: { string },
    wrongAt: number,
    -- isolate
    job: string,
    tagged: { [string]: boolean },
    wrongValve: string?,
    -- spot / evidence (from the step: ctx)
    ctx: any,
    stage: string, -- spot: "decide" or "finding"
    pinned: { [number]: boolean },
    pick: number?,
    -- contain
    radii: { number },
    socks: { [number]: boolean },
    signed: boolean,
    reported: boolean,
    variant: number, -- tower: 1 cell 2 offline, 2 fans stuck in HAND
    hand: boolean,
    -- drive
    drive: number,
    screen: string,
    found: { [string]: boolean },
}

local BG = Color.rgba(18, 22, 28, 248)
local PANEL = Color.rgb(30, 36, 44)
local LINE = Color.rgb(58, 66, 78)
local FG = Color.rgb(234, 238, 242)
local MUTED = Color.rgb(150, 162, 176)
local GREEN = Color.rgb(84, 214, 120)
local RED = Color.rgb(236, 82, 70)
local AMBER = Color.rgb(246, 176, 46)
local BLUE = Color.rgb(70, 160, 255)
local WATER = Color.rgb(44, 120, 220)
local DRY = Color.rgb(74, 82, 94)
local INK = Color.rgb(12, 16, 20)
local WHITE_TAG = Color.rgb(240, 240, 236)

local FLOW_DESIGN, FLOW_LO, FLOW_HI, FLOW_MAX = 1500, 1450, 1550, 2000 -- round 2 moves the target (Games.new)
local WHEEL_X, WHEEL_Y = 210, 300 -- the balancing handwheel's center
local TURNS_PER_REV = 1.5 -- valve turns per full twist of the wheel (it's geared)

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

-- Every helper takes r = nil for a layout-only pass (hit regions, no drawing).
local function rr(r: Renderer?, x: number, y: number, w: number, h: number, rad: number, color: Color)
    if r ~= nil then UI.roundRect(r, x, y, w, h, rad, color) end
end

-- Random faults: when the other pump failed, every CHWP-1 / Drive 1 the player sees swaps
-- with CHWP-2 / Drive 2 (set per game in Games.paint).
local SWAP = false
local CHILLER = 1 -- the chiller this game is about: "CH-1" in the text reads as CH-<n>
local function swapPumps(s: string): string
    if CHILLER ~= 1 then s = string.gsub(s, "CH%-1", "CH-" .. CHILLER) end
    if not SWAP then return s end
    s = string.gsub(s, "CHWP%-1", "\1"); s = string.gsub(s, "CHWP%-2", "CHWP-1"); s = string.gsub(s, "\1", "CHWP-2")
    s = string.gsub(s, "Drive 1", "\1"); s = string.gsub(s, "Drive 2", "Drive 1"); s = string.gsub(s, "\1", "Drive 2")
    return s
end
Games.swapPumps = function(s: string, on: boolean, chiller: number?): string
    local was, wasC = SWAP, CHILLER
    SWAP, CHILLER = on, chiller or 1
    local out = swapPumps(s)
    SWAP, CHILLER = was, wasC
    return out
end

local function txt(r: Renderer?, s: string, font: Art.FontRef, size: number, color: Color, x: number, y: number, w: number, align: TextAlign?)
    if r ~= nil then Art.text(r, swapPumps(s), font, size, color, x, y, w, align) end
end

local function disc(r: Renderer?, cx: number, cy: number, rad: number, color: Color)
    if r ~= nil then Art.disc(r, cx, cy, rad, color) end
end

local function fill(r: Renderer?, p: Path, paint: Paint)
    if r ~= nil then r:drawPath(p, paint) end
end

local function line(r: Renderer?, pts: { number }, color: Color, thick: number)
    local p = Path.new()
    p:moveTo(Vector.xy(pts[1], pts[2]))
    for i = 3, #pts, 2 do p:lineTo(Vector.xy(pts[i], pts[i + 1])) end
    fill(r, p, Paint.with({ style = "stroke", thickness = thick, color = color, join = "round", cap = "round" }))
end

local function ring(r: Renderer?, cx: number, cy: number, rad: number, color: Color, thick: number)
    local k = rad * 0.5523
    local p = Path.new()
    p:moveTo(Vector.xy(cx + rad, cy))
    p:cubicTo(Vector.xy(cx + rad, cy + k), Vector.xy(cx + k, cy + rad), Vector.xy(cx, cy + rad))
    p:cubicTo(Vector.xy(cx - k, cy + rad), Vector.xy(cx - rad, cy + k), Vector.xy(cx - rad, cy))
    p:cubicTo(Vector.xy(cx - rad, cy - k), Vector.xy(cx - k, cy - rad), Vector.xy(cx, cy - rad))
    p:cubicTo(Vector.xy(cx + k, cy - rad), Vector.xy(cx + rad, cy - k), Vector.xy(cx + rad, cy))
    p:close()
    fill(r, p, Paint.with({ style = "stroke", thickness = thick, color = color }))
end

local function wrap(font: Art.FontRef, s: string, size: number, w: number): { string }
    local out: { string } = {}
    local cur = ""
    for word in string.gmatch(s, "%S+") do
        local test = if cur == "" then word else cur .. " " .. word
        if cur ~= "" and Art.measure(font, test, size) > w then
            table.insert(out, cur)
            cur = word
        else
            cur = test
        end
    end
    if cur ~= "" then table.insert(out, cur) end
    return out
end

local function button(r: Renderer?, hits: { Hit }, f: Art.Fonts, x: number, y: number, w: number, h: number, label: string, action: string, style: string?)
    local bg = if style == "primary" then GREEN elseif style == "warn" then AMBER elseif style == "quiet" then Color.rgba(255, 255, 255, 18) else Color.rgb(48, 56, 68)
    rr(r, x, y, w, h, h / 2, bg)
    local fg = if style == "primary" or style == "warn" then INK else FG
    txt(r, label, f.bold, 14, fg, x + 10, y + (h - 14) / 2 - 1, w - 20, "center")
    table.insert(hits, { x = x, y = y, w = w, h = h, action = action })
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function Games.new(kind: string, ctx: any?): Game
    local g: Game = {
        kind = kind, title = "", intro = "", t = 0, tries = 0, solved = false, solvedAt = 0, stars = 0, summary = "",
        message = nil, messageGood = false, limit = 60, timedOut = false,
        cards = {}, picked = nil, locked = {}, flash = {}, lo = {}, holding = nil, spark = -10,
        valves = {}, fan = 60, cell2 = false, temp = 92.8, hold = 0, flatOut = 0,
        turns = 10, flow = 2000, dragX = 0, dragTurns = 10, dragAngle = 0, wheelAngle = -math.pi / 2, grabbed = false,
        tool = nil, part = nil, checked = {}, mistakes = 0,
        drive = 1, screen = "home", found = {},
        matched = {}, selValve = nil, jobOrder = {}, wrongAt = -10, job = "cond", tagged = {}, wrongValve = nil,
        ctx = ctx or {}, stage = "decide", pinned = {}, pick = nil,
        radii = {}, socks = {}, signed = false, reported = false, variant = 1, hand = false,
    }
    if kind == "lockout" then
        g.title = "Lock out CHWP-1"
        g.intro = "Make CHWP-1 safe for the mechanic. Each item has one button: press them in the safe order. A wrong move tells you why."
        g.summary = "CHWP-1 is locked out: it can't start while someone works on it."
    elseif kind == "lineup" then
        g.title = "Isolate CHWP-1"
        g.intro = "CHWP-1 tripped and will be repaired. Isolate it so no water reaches it, and keep chilled water flowing to CH-1 through CHWP-2. Click a valve to open or close it."
        g.valves = { S1 = true, D1 = true, S2 = true, D2 = Games.round < 2, BYP = false }
        if Games.round >= 2 then g.intro ..= " Round 2: the last shift left the line-up a mess, so check every valve." end
        g.summary = "CHWP-1 is isolated for repair, and CHWP-2 keeps CH-1 supplied."
    elseif kind == "tower" then
        g.title = "Cool the condenser water"
        g.intro = "Condenser water reaches CH-1 too warm. From the plant controls, bring it into the green band (80-86 °F) and hold it there. The water takes a few seconds to respond."
        g.summary = "Condenser water is back in range: CH-1 can make full capacity again."
        g.variant = if Games.round >= 2 then 3 else math.random(1, 2)
        if g.variant == 3 then
            g.cell2, g.hand, g.fan = false, true, 35 -- round 2: cell 2 offline AND the fans stuck in HAND
            g.intro = "Round 2: condenser water is too warm and more than one thing is wrong. Bring it into the green band (80-86 °F) and hold it."
        elseif g.variant == 2 then
            g.cell2, g.hand, g.fan = true, true, 35
            g.intro = "Condenser water reaches CH-1 too warm. From the plant controls, bring it into the green band (80-86 °F) and hold it. The water takes a few seconds to respond."
        end
    elseif kind == "inspect" then
        g.title = "Inspect pump CHWP-1"
        g.intro = "Is CHWP-1 really broken? Click a part of the pump, choose how to check it, and find the 4 clues that prove it failed."
        g.summary = "CHWP-1 is stopped, still hot and not pumping: it tripped. Its drive will tell you why."
    elseif kind == "drive" then
        g.title = "Read the pump drives"
        g.intro = "Find out why CHWP-1 stopped. Pick a drive, press its keys like on the real panel, and answer the 3 questions on the right."
        g.summary = "Drive 1 tripped on F005, motor overload (132 % current). CHWP-2 started automatically, so the chiller still has flow."
    elseif kind == "match" then
        g.title = "Match the valves"
        g.intro = "Every valve in the plant has a job. Click a valve on the left, then the job it does on the right."
        g.summary = "You know the plant's five kinds of valve and what each one is for."
        local order = if Games.round >= 2 then { "iso", "bal", "mot", "byp", "suc", "chk", "rlf" } else { "iso", "bal", "mot", "byp", "suc" }
        if Games.round >= 2 then g.intro ..= " Round 2: two more kinds of valve." end
        g.summary = string.format("You know the plant's %d kinds of valve and what each one is for.", #order)
        for i = #order, 2, -1 do
            local j = math.random(1, i)
            order[i], order[j] = order[j], order[i]
        end
        g.jobOrder = order
    elseif kind == "isolate" then
        local jobs = if Games.round >= 2 then { "cond", "evap", "both" } else { "cond", "evap" }
        g.job = jobs[math.random(1, #jobs)]
        g.title = "Isolate CH-1 for a work order"
        g.intro = "Cut the part named on the work order off from its water, so a mechanic can open it safely. Click a valve to close it."
        g.valves = { CHWR = true, CHWS = true, CWS = true, CWR = true }
        g.tagged = {}
        g.wrongValve = nil
        g.summary = if g.job == "both"
            then "CH-1 is fully isolated: all four valves shut, locked and tagged, ready for the teardown."
            elseif g.job == "cond"
            then "The condenser is isolated: both condenser water valves shut, locked and tagged. The chilled water side stays ready."
            else "The evaporator is isolated: both chilled water valves shut, locked and tagged. The condenser side stays ready."
    elseif kind == "spot" then
        local c = g.ctx
        g.title = "Check: " .. (c.name or "")
        g.intro = "Read it fast: is everything here normal? The clock is running."
        g.summary = c.summary or "Checked."
    elseif kind == "evidence" then
        local c = g.ctx
        g.title = c.title or "Evidence board"
        g.intro = "Pin the clues that prove what happened (click them), then pick the conclusion they prove. Not every clue matters."
        g.summary = c.summary or "Case solved."
    elseif kind == "contain" then
        g.title = "Contain the leak"
        g.intro = "Water is spreading across the floor toward the 480 V motor control center. Lay absorbent socks around it (block the electrical side first!), put a wet-floor sign on the walkway, and report it."
        g.summary = "Leak contained: the water can't reach the electrical gear, the walkway is signed and the control room knows."
        for i = 1, 8 do g.radii[i] = 34 end
    elseif kind == "balance" then
        g.title = "Balance the condenser water"
        if Games.round >= 2 then
            FLOW_DESIGN, FLOW_LO, FLOW_HI = 1350, 1320, 1380
        else
            FLOW_DESIGN, FLOW_LO, FLOW_HI = 1500, 1450, 1550
        end
        g.intro = string.format("Someone opened CH-1's balancing valve wide and the condenser gets too much water. Grab the handwheel and twist it (circle the mouse or trackpad around it) until the flow meter settles at %d gpm, then hold it.", FLOW_DESIGN)
            .. (if Games.round >= 2 then " Round 2: a new report, and a tighter band." else "")
        g.summary = string.format("Condenser flow is back at its design %d gpm, as the balancing report says.", FLOW_DESIGN)
    end
    g.limit = math.max(8, math.round((TIME_LIMIT[kind] or 60) * Games.difficulty))
    return g
end

local function solve(g: Game)
    g.solved = true
    g.solvedAt = g.t
    if g.kind == "spot" then
        g.stars = if g.mistakes == 0 and g.t <= (if Games.round >= 2 then 5 else 8) then 3 elseif g.mistakes == 0 then 2 else 1
    elseif g.kind == "contain" then
        g.stars = if g.mistakes == 0 and g.t <= 30 then 3 elseif g.mistakes == 0 then 2 else 1
    elseif g.kind == "evidence" then
        g.stars = if g.tries <= 1 then 3 elseif g.tries == 2 then 2 else 1
    elseif g.kind == "lockout" then
        g.stars = if g.mistakes == 0 then 3 elseif g.mistakes <= 2 then 2 else 1
    elseif g.kind == "tower" or g.kind == "balance" then
        g.stars = if g.t <= 35 then 3 elseif g.t <= 70 then 2 else 1
    elseif g.kind == "inspect" or g.kind == "drive" or g.kind == "match" then
        g.stars = if g.mistakes == 0 then 3 elseif g.mistakes <= 2 then 2 else 1
    else
        g.stars = if g.tries <= 1 then 3 elseif g.tries == 2 then 2 else 1
    end
end

-- What gold takes, shown beside the clock.
local function goldTarget(g: Game): string
    local k = g.kind
    if k == "tower" or k == "balance" then return "Gold: under 0:35" end
    if k == "spot" then return if Games.round >= 2 then "Gold: right, under 0:05" else "Gold: right, under 0:08" end
    if k == "contain" then return "Gold: no spill, under 0:30" end
    if k == "isolate" then return "Gold: no wrong valves" end
    if k == "lineup" or k == "evidence" then return "Gold: right first time" end
    return "Gold: no mistakes"
end

local function clock(t: number): string
    return string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60))
end

-- ---------------------------------------------------------------------------
-- Rules
-- ---------------------------------------------------------------------------

local function checkLineup(g: Game): (boolean, string)
    local v = g.valves
    if not v.S2 or not v.D2 then
        return false, "CHWP-2 is running: with one of its valves closed it pumps against a dead end and CH-1 loses its flow."
    end
    if v.BYP then
        return false, "The bypass is open: water short-circuits back to the pumps instead of going through CH-1."
    end
    if v.S1 or v.D1 then
        return false, "CHWP-1 isn't isolated yet: water can still reach it. Close both of its valves."
    end
    return true, "Correct line-up."
end

local TOWER_BAND_LO, TOWER_BAND_HI = 80, 86

-- A balancing valve passes most of its flow in the first turns: flow rises steeply, then flattens.
local function valveFlow(turns: number): number
    return FLOW_MAX * (math.clamp(turns, 0, 10) / 10) ^ 0.6
end

local function towerTarget(g: Game): number
    local cells = if g.cell2 then 2 else 1
    return 100 - g.fan * 0.12 * cells
end

function Games.step(g: Game, dt: number)
    if g.timedOut then return end
    g.t += dt
    if not g.solved and g.t >= g.limit then
        g.t = g.limit
        g.timedOut = true
        g.message = nil
        return
    end
    if g.kind == "contain" and not g.solved then
        -- The floor slopes toward the electrical side (direction 1, east), so water runs that way fastest.
        for i = 1, 8 do
            local speed = (if i == 1 then 15 elseif i == 2 or i == 8 then 11 else 7) * (if Games.round >= 2 then 1.35 else 1)
            local cap = if g.socks[i] then 104 else 400
            g.radii[i] = math.min(cap, g.radii[i] + speed * dt)
            if g.radii[i] >= 196 then
                g.mistakes += 1
                g.message, g.messageGood = "The water reached the electrical panel! The puddle is mopped back: block the electrical side first this time.", false
                for j = 1, 8 do g.radii[j] = 34 end
                break
            end
        end
    end
    if g.kind == "tower" and not g.solved then
        g.temp += (towerTarget(g) - g.temp) * (1 - math.exp(-dt / 2.2))
        if g.temp >= TOWER_BAND_LO and g.temp <= TOWER_BAND_HI then
            g.hold += dt
            if g.hold >= 4 then solve(g) end
        else
            g.hold = 0
        end
        if g.fan >= 95 and not g.cell2 then g.flatOut += dt else g.flatOut = 0 end
    elseif g.kind == "balance" and not g.solved then
        g.flow += (valveFlow(g.turns) - g.flow) * (1 - math.exp(-dt / 0.7))
        if g.flow >= FLOW_LO and g.flow <= FLOW_HI then
            g.hold += dt
            if g.hold >= 3 then solve(g) end
        else
            g.hold = 0
        end
    end
end

-- The pump's parts: where they are, the tool that checks them, what it finds,
-- whether that's a clue it failed, and what each wrong tool tells you.
type Part = { key: string, name: string, x: number, y: number, rad: number, tool: string, finding: string, clue: string?, wrong: { [string]: string } }
local PARTS: { Part } = {
    { key = "coupling", name = "Coupling", x = 330, y = 300, rad = 34, tool = "look",
        finding = "The coupling is still: the shaft isn't turning.", clue = "Shaft not turning",
        wrong = { temp = "Temperature can't tell you whether the shaft turns. Look at it.", listen = "Hard to hear a coupling. Just look: is it spinning?" } },
    { key = "motor", name = "Motor", x = 440, y = 300, rad = 62, tool = "temp",
        finding = "Motor casing 62 °C, much hotter than the running CHWP-2 (45 °C): it was overloaded before it stopped.", clue = "Motor hot: overloaded",
        wrong = { look = "It looks normal from outside. Its temperature tells you more.", listen = "It's silent, but the motor's heat tells you more. Try the thermometer." } },
    { key = "casing", name = "Pump casing", x = 170, y = 300, rad = 56, tool = "listen",
        finding = "Silent: no water rushing, no bearing hum. It isn't pumping.", clue = "Pump silent",
        wrong = { look = "The casing looks the same running or stopped. Listen to it.", temp = "The water keeps the casing cool either way. Listen instead." } },
    { key = "discharge", name = "Discharge gauge", x = 236, y = 170, rad = 28, tool = "look",
        finding = "Discharge 150 kPa: the same as suction. The pump adds no pressure.", clue = "No pressure rise",
        wrong = { temp = "A gauge is read, not measured. Look at the needle.", listen = "Gauges don't make a sound. Read it." } },
    { key = "seal", name = "Shaft seal", x = 252, y = 300, rad = 18, tool = "look",
        finding = "Seal dry, no drips: normal. Not a clue.", clue = nil,
        wrong = { temp = "Look for drips at the seal instead.", listen = "Look for drips at the seal instead." } },
    { key = "suction", name = "Suction gauge", x = 74, y = 236, rad = 26, tool = "look",
        finding = "Suction 150 kPa: water is reaching the pump, so the inlet is fine. Not a clue.", clue = nil,
        wrong = { temp = "A gauge is read, not measured. Look at the needle.", listen = "Gauges don't make a sound. Read it." } },
}
local CLUES = 4

local function cluesFound(g: Game): number
    local n = 0
    for _, p in PARTS do if p.clue ~= nil and g.checked[p.key] then n += 1 end end
    return n
end

local VALVE_TYPES: { [string]: { name: string, job: string, why: string } } = {
    iso = { name = "Isolation valve", job = "Shuts the chiller's water off completely for maintenance.", why = "Isolation valves are fully open or fully shut: they cut equipment off for work." },
    bal = { name = "Balancing valve", job = "Set once, during commissioning, to give the right design flow.", why = "A balancing valve is set to a flow and then left alone: its handwheel has a memory stop." },
    mot = { name = "Motorized valve", job = "Opens and closes by itself when the chiller starts or stops.", why = "A motorized valve has an actuator on top: the control system moves it, not a person." },
    byp = { name = "Bypass valve", job = "Lets water skip past to keep a minimum flow through the chiller.", why = "The bypass connects supply to return, so some water always circulates at low load." },
    chk = { name = "Check valve", job = "Lets water flow one way only, so a stopped pump can't spin backwards.", why = "A check valve's flap closes when flow reverses: it protects the standby pump." },
    rlf = { name = "Relief valve", job = "Opens by itself if pressure gets dangerously high.", why = "A relief valve is the last line of defense against overpressure: never block it." },
    suc = { name = "Pump suction valve", job = "Cuts off the water into a pump so the pump can be repaired.", why = "Suction valves sit on a pump's inlet; closing it (and the discharge) isolates the pump." },
}

-- The isolate game: which valves the work order needs shut, and what that cuts off.
local function isolateNeeds(g: Game): { [string]: boolean }
    if g.job == "both" then return { CWS = true, CWR = true, CHWS = true, CHWR = true } end
    if g.job == "cond" then return { CWS = true, CWR = true } end
    return { CHWS = true, CHWR = true }
end

local function isolatePart(g: Game): string
    return if g.job == "both" then "whole chiller" elseif g.job == "cond" then "condenser" else "evaporator"
end

-- A click on one of the panel's hit regions.
function Games.action(g: Game, a: string)
    if g.solved or g.timedOut then return end
    if g.kind == "spot" then
        local c = g.ctx
        if a == "normal" then
            if c.bad then
                g.mistakes += 1
                g.message, g.messageGood = "Look again: something here is out of range.", false
            else
                g.message, g.messageGood = "Right: all normal.", true
                solve(g)
            end
        elseif a == "problem" then
            if c.bad then
                g.stage = "finding"
                g.message = nil
            else
                g.mistakes += 1
                g.message, g.messageGood = "Everything here is in its normal range. Check the green bands again.", false
            end
        elseif string.sub(a, 1, 8) == "finding:" then
            local i = tonumber(string.sub(a, 9)) or 0
            local fnd = (c.findings or {})[i]
            if fnd == c.problem then
                g.message, g.messageGood = "Spotted: " .. (c.clue or fnd), true
                solve(g)
            else
                g.mistakes += 1
                g.message, g.messageGood = "Not that. Which reading is outside its band?", false
            end
        end
        return
    end
    if g.kind == "evidence" then
        local c = g.ctx
        if string.sub(a, 1, 4) == "pin:" then
            local i = tonumber(string.sub(a, 5)) or 0
            g.pinned[i] = not g.pinned[i]
            g.message = nil
        elseif string.sub(a, 1, 5) == "pick:" then
            g.pick = tonumber(string.sub(a, 6))
            g.message = nil
        elseif a == "solve" then
            if g.pick == nil then g.message, g.messageGood = "Pick a conclusion first.", false; return end
            g.tries += 1
            local choice = c.choices[g.pick]
            if not choice.correct then
                g.message, g.messageGood = choice.feedback, false
                return
            end
            for i, cl in c.clues do
                if g.pinned[i] and not cl.relevant then
                    g.message, g.messageGood = "\"" .. cl.text .. "\" is true, but it doesn't prove this. " .. (cl.why or "Unpin it."), false
                    return
                end
            end
            for i, cl in c.clues do
                if cl.relevant and not g.pinned[i] then
                    g.message, g.messageGood = "Right conclusion! But one more clue proves it. Pin every clue that supports it.", false
                    return
                end
            end
            g.message, g.messageGood = choice.feedback, true
            solve(g)
        end
        return
    end
    if g.kind == "contain" then
        if string.sub(a, 1, 5) == "sock:" then
            g.socks[tonumber(string.sub(a, 6)) or 0] = true
        elseif a == "sign" then
            g.signed = true
            g.message, g.messageGood = "Wet-floor sign up: nobody slips walking past.", true
        elseif a == "report" then
            g.reported = true
            g.message, g.messageGood = "Control room: \"Thanks. We'll raise a work order and keep people clear.\"", true
        end
        local all = true
        for i = 1, 8 do if not g.socks[i] then all = false end end
        if all and g.signed and g.reported then solve(g) end
        return
    end
    if g.kind == "match" then
        if string.sub(a, 1, 3) == "mv:" then
            local k = string.sub(a, 4)
            if not g.matched[k] then g.selValve = if g.selValve == k then nil else k end
            g.message = nil
        elseif string.sub(a, 1, 3) == "mj:" then
            local k = string.sub(a, 4)
            local v = g.selValve
            if g.matched[k] then return end
            if v == nil then
                g.message, g.messageGood = "Click a valve on the left first.", false
            elseif v == k then
                g.matched[k] = true
                g.selValve = nil
                g.message, g.messageGood = "Right! " .. VALVE_TYPES[k].why, true
                local n = 0
                for _ in g.matched do n += 1 end
                if n == #g.jobOrder then solve(g) end
            else
                g.mistakes += 1
                g.wrongAt = g.t
                g.message, g.messageGood = "Not that one. " .. VALVE_TYPES[v].why, false
            end
        end
        return
    end
    if g.kind == "isolate" then
        local need = isolateNeeds(g)
        if string.sub(a, 1, 6) == "valve:" then
            local k = string.sub(a, 7)
            local v = g.valves
            if not need[k] then
                -- The wrong side: say so on the spot, and leave it open.
                g.mistakes += 1
                g.wrongValve, g.wrongAt = k, g.t
                g.message, g.messageGood = string.format("Not %s: it's on the %s side. The work order only needs the %s.",
                    k, if string.sub(k, 1, 2) == "CH" then "chilled water (evaporator)" else "condenser water", isolatePart(g)), false
                return
            end
            if v[k] then
                v[k] = false
                local left = 0
                for key in need do if v[key] then left += 1 end end
                g.message, g.messageGood = if left > 0
                    then string.format("%s closed. %d more to go.", k, left)
                    else "Isolated! Now lock and tag each closed valve: click it.", true
            elseif not g.tagged[k] then
                local left = 0
                for key in need do if g.valves[key] then left += 1 end end
                if left > 0 then
                    g.message, g.messageGood = "Close all of them first, then lock and tag.", false
                else
                    g.tagged[k] = true
                    local untagged = 0
                    for key in need do if not g.tagged[key] then untagged += 1 end end
                    if untagged == 0 then
                        solve(g)
                    else
                        g.message, g.messageGood = string.format("%s locked and tagged. %d to go.", k, untagged), true
                    end
                end
            end
        end
        return
    end
    if g.kind == "inspect" then
        if string.sub(a, 1, 5) == "part:" then
            g.part = string.sub(a, 6)
            g.message = nil
        elseif string.sub(a, 1, 5) == "tool:" then
            local tool = string.sub(a, 6)
            for _, p in PARTS do
                if p.key == g.part then
                    if tool ~= p.tool then
                        g.mistakes += 1
                        g.message, g.messageGood = (p.wrong[tool] or "Try another way."), false
                    else
                        g.checked[p.key] = true
                        g.message, g.messageGood = p.finding, p.clue ~= nil
                        g.part = nil
                        if cluesFound(g) >= CLUES then solve(g) end
                    end
                end
            end
        end
        return
    end
    if g.kind == "drive" then
        if a == "drv:1" or a == "drv:2" then
            g.drive = if a == "drv:1" then 1 else 2
            g.screen = "home"
            g.message = nil
        elseif a == "key:back" then
            g.screen = "home"
        elseif a == "key:fault" then
            g.screen = "faults"
            if g.drive == 1 and not g.found.code then
                g.found.code = true
                g.message, g.messageGood = "Drive 1 tripped on fault F005: motor overload.", true
            end
        elseif a == "key:next" then
            if g.drive == 1 and (g.screen == "faults" or g.screen == "detail") then
                g.screen = "detail"
                if not g.found.current then
                    g.found.current = true
                    g.message, g.messageGood = "At the trip the motor drew 132 % of its rated current. The limit is 115 %.", true
                end
            else
                g.message, g.messageGood = "NEXT shows more about a fault. Open a FAULT LOG first.", false
            end
        elseif a == "key:status" then
            g.screen = "status"
        elseif a == "key:reset" then
            g.mistakes += 1
            g.message, g.messageGood = if g.drive == 1
                then "Don't reset it! A motor that tripped on overload can burn out if it's restarted before someone finds the cause."
                else "Drive 2 is running fine: there's nothing to reset.", false
        end
        if g.drive == 2 and (g.screen == "home" or g.screen == "status") and not g.found.standby then
            g.found.standby = true
            g.message, g.messageGood = "CHWP-2 started by itself (AUTO STANDBY) when CHWP-1 tripped, so water keeps flowing.", true
        end
        if g.found.code and g.found.current and g.found.standby then solve(g) end
        return
    end
    if g.kind == "lockout" then
        local lo = g.lo
        local function say(text: string, good: boolean) g.message, g.messageGood = text, good end
        local function oops(text: string) g.mistakes += 1; say(text, false) end
        if a == "lo:radio" and not lo.radio then
            lo.radio = true
            say("Control room: \"Understood. CHWP-1 is out of service, we won't start it.\"", true)
        elseif a == "lo:stop" and not lo.stopped then
            if not lo.radio then
                oops("Call the control room first: they'd see CHWP-1 stop and might start it again from their screens.")
            else
                lo.stopped = true
                say("Drive stopped and set to OFF: it can't restart the pump.", true)
            end
        elseif a == "lo:off" and not lo.off then
            if not lo.stopped then
                g.spark = g.t
                oops("Arc flash! Pulling the switch while the drive can run is dangerous. Stop the drive first.")
            else
                lo.off = true
                say("Switch OFF: no power can reach the motor.", true)
            end
        elseif a == "lo:lock" and not lo.locked then
            if not lo.off then
                oops("The padlock only fits the switch handle in the OFF position. Switch it off first.")
            else
                lo.locked = true
                say("Locked and tagged: only your key opens it, and the tag says who and why.", true)
            end
        elseif a == "lo:start" then
            if not lo.locked then
                oops("Not yet! Only test once it's locked out: never test a pump that could really start.")
            else
                say("You press START: nothing happens. Zero energy confirmed.", true)
                solve(g)
            end
        end
        return
    elseif g.kind == "lineup" then
        if string.sub(a, 1, 6) == "valve:" then
            local k = string.sub(a, 7)
            g.valves[k] = not g.valves[k]
            g.message = nil
        elseif a == "check" then
            g.tries += 1
            local ok, why = checkLineup(g)
            if ok then solve(g) else g.message = why; g.messageGood = false end
        end
    elseif g.kind == "tower" then
        if a == "hand" then g.hand = not g.hand; g.message = nil
        elseif g.hand and (a == "fan-" or a == "fan+") then
            g.message, g.messageGood = "The fans are in HAND: they ignore the controls. Switch them to AUTO.", false
        elseif a == "fan-" then g.fan = math.max(0, g.fan - 5)
        elseif a == "fan+" then g.fan = math.min(100, g.fan + 5)
        elseif a == "cell2" then g.cell2 = not g.cell2 end
    elseif g.kind == "balance" then
        local d = tonumber(string.match(a, "^turn:(.+)$") or "")
        if d ~= nil then
            local before = g.turns
            g.turns = math.clamp(g.turns + d, 0, 10)
            g.wheelAngle -= (g.turns - before) / TURNS_PER_REV * 2 * math.pi
        end
    end
end

-- Dragging: the tower's fan slider follows x; the balancing handwheel turns with it
-- (drag right = clockwise = closing). x is in panel points.
local SLIDER_X0, SLIDER_X1, SLIDER_Y = 96, 416, 440

function Games.dragStart(g: Game, x: number, y: number?)
    g.dragX, g.dragTurns = x, g.turns
    g.dragAngle = math.atan2((y or 0) - WHEEL_Y, x - WHEEL_X)
    g.grabbed = g.kind == "balance"
end

-- Dragging: the tower's fan slider follows x; the balancing handwheel turns with the
-- pointer circling its centre (clockwise closes, like a real valve). x, y in panel points.
function Games.drag(g: Game, x: number, y: number?)
    if g.solved or g.timedOut then return end
    if g.kind == "tower" and g.hand then
        g.message, g.messageGood = "The fans are in HAND: they ignore the controls. Switch them to AUTO.", false
        return
    end
    if g.kind == "tower" then
        local f = math.clamp((x - SLIDER_X0) / (SLIDER_X1 - SLIDER_X0), 0, 1)
        g.fan = math.round(f * 100)
    elseif g.kind == "balance" then
        local dx, dy = x - WHEEL_X, (y or 0) - WHEEL_Y
        if dx * dx + dy * dy < 14 * 14 then return end -- too close to the hub to tell a direction
        local a = math.atan2(dy, dx)
        local d = a - g.dragAngle
        if d > math.pi then d -= 2 * math.pi elseif d < -math.pi then d += 2 * math.pi end
        g.dragAngle = a
        local before = g.turns
        g.turns = math.clamp(g.turns - d / (2 * math.pi) * TURNS_PER_REV, 0, 10)
        -- The wheel turns exactly as far as the valve did, so it stops dead at fully open or shut.
        g.wheelAngle -= (g.turns - before) / TURNS_PER_REV * 2 * math.pi
    end
end

function Games.dragEnd(g: Game)
    g.grabbed = false
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

local function paintLockout(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    local lo = g.lo
    local BOX = Color.rgb(64, 70, 80)
    local function card(x: number, y: number, w: number, h: number, title: string, isDone: boolean)
        rr(r, x, y, w, h, 12, if isDone then Color.rgba(84, 214, 120, 30) else PANEL)
        txt(r, title, f.bold, 11, if isDone then GREEN else MUTED, x + 12, y + 10, w - 24)
        if isDone then
            disc(r, x + w - 18, y + 16, 10, GREEN)
            line(r, { x + w - 23, y + 16, x + w - 19, y + 20, x + w - 13, y + 12 }, INK, 2.5)
        end
    end
    -- One button per item; once done it becomes a quiet status line.
    local function act(x: number, y: number, w: number, label: string, action: string, isDone: boolean, doneText: string)
        if isDone then
            txt(r, doneText, f.bold, 13, GREEN, x, y + 11, w, "center")
        else
            button(r, hits, f, x, y, w, 36, label, action, "primary")
        end
    end
    -- Radio.
    card(24, 112, 180, 150, "RADIO", lo.radio == true)
    rr(r, 90, 136, 48, 70, 8, Color.rgb(40, 44, 50))
    line(r, { 128, 136, 128, 120 }, Color.rgb(40, 44, 50), 5)
    rr(r, 98, 146, 32, 20, 3, Color.rgb(110, 200, 140))
    for i = 0, 2 do rr(r, 98, 174 + i * 10, 32, 4, 2, Color.rgb(80, 86, 96)) end
    act(36, 216, 156, "Call control room", "lo:radio", lo.radio == true, "Control room told")
    -- Drive.
    card(24, 276, 180, 176, "CHWP-1 DRIVE", lo.stopped == true)
    rr(r, 40, 300, 148, 54, 6, Color.rgb(10, 26, 18))
    txt(r, if lo.stopped then "STOPPED" else "TRIPPED", f.mono, 15, if lo.stopped then Color.rgb(110, 240, 150) else Color.rgb(255, 110, 90), 50, 308, 130)
    txt(r, if lo.stopped then "MODE: OFF" else "MODE: AUTO", f.mono, 13, Color.rgb(110, 240, 150), 50, 330, 130)
    act(36, 404, 156, "Stop the drive", "lo:stop", lo.stopped == true, "Stopped, mode OFF")
    -- Disconnect switch: handle up = ON, down = OFF; the lock and tag hang on it once applied.
    card(224, 112, 230, 340, "CHWP-1 DISCONNECT  480 V", lo.off == true)
    rr(r, 254, 136, 170, 252, 10, BOX)
    rr(r, 266, 148, 146, 28, 4, Color.rgb(236, 180, 30))
    txt(r, "DANGER 480 V", f.bold, 13, INK, 266, 155, 146, "center")
    local px, py = 339, 274
    txt(r, "ON", f.bold, 14, if lo.off then MUTED else GREEN, px + 26, 188, 40)
    txt(r, "OFF", f.bold, 14, if lo.off then RED else MUTED, px + 26, 344, 40)
    local tipY = if lo.off then py + 70 else py - 70
    line(r, { px, py, px, tipY }, Color.rgb(150, 30, 26), 16)
    rr(r, px - 22, tipY - 10, 44, 20, 8, Color.rgb(180, 40, 34))
    disc(r, px, py, 16, Color.rgb(40, 44, 50))
    if lo.locked then
        ring(r, px - 37, py + 62, 10, Color.rgb(200, 204, 210), 4)
        rr(r, px - 52, py + 64, 30, 28, 5, Color.rgb(220, 60, 40))
        rr(r, px - 104, py + 60, 48, 40, 4, WHITE_TAG)
        rr(r, px - 104, py + 60, 48, 13, 4, RED)
        txt(r, "DANGER", f.bold, 8.5, FG, px - 104, py + 62, 48, "center")
        txt(r, "DO NOT", f.bold, 7.5, INK, px - 104, py + 77, 48, "center")
        txt(r, "OPERATE", f.bold, 7.5, INK, px - 104, py + 87, 48, "center")
    end
    if g.t - g.spark < 0.7 then
        local k = 1 - (g.t - g.spark) / 0.7
        for i = 0, 9 do
            local a = i * math.pi / 5 + g.t * 3
            line(r, { px + math.cos(a) * 20, py - 40 + math.sin(a) * 20, px + math.cos(a) * (40 + 50 * k), py - 40 + math.sin(a) * (40 + 50 * k) }, Color.rgba(255, 230, 120, math.round(255 * k)), 4)
        end
        disc(r, px, py - 40, 24 * k + 6, Color.rgba(255, 255, 220, math.round(230 * k)))
    end
    act(246, 404, 186, "Switch it OFF", "lo:off", lo.off == true, "OFF: no power")
    -- Start station: the test.
    card(474, 112, 150, 200, "PUMP START", g.solved)
    rr(r, 509, 136, 80, 112, 10, Color.rgb(56, 62, 72))
    disc(r, 549, 172, 26, Color.rgb(40, 160, 80))
    txt(r, "START", f.bold, 11, FG, 519, 166, 60, "center")
    disc(r, 549, 224, 14, Color.rgb(170, 40, 34))
    act(486, 264, 126, "Test START", "lo:start", g.solved, "Nothing happens")
    -- Your kit: padlock and tag, applied together.
    card(474, 326, 322, 126, "YOUR KIT", lo.locked == true)
    ring(r, 520, 364, 9, Color.rgb(200, 204, 210), 4)
    rr(r, 506, 366, 28, 24, 5, Color.rgb(220, 60, 40))
    rr(r, 548, 356, 40, 36, 4, WHITE_TAG)
    rr(r, 548, 356, 40, 11, 4, RED)
    txt(r, "Padlock and danger tag", f.body, 12.5, MUTED, 600, 366, 180)
    act(490, 404, 290, "Lock & tag the switch", "lo:lock", lo.locked == true, "Locked and tagged")
    -- Goal and progress.
    rr(r, 640, 112, 156, 200, 12, Color.rgba(70, 160, 255, 26))
    txt(r, "GOAL", f.bold, 11, BLUE, 652, 122, 132)
    local gy = 142
    for _, l in wrap(f.body, "Nobody and nothing can start CHWP-1, and you've proved it.", 13.5, 132) do
        txt(r, l, f.body, 13.5, FG, 652, gy, 132)
        gy += 18
    end
    local n = (if lo.radio then 1 else 0) + (if lo.stopped then 1 else 0) + (if lo.off then 1 else 0) + (if lo.locked then 1 else 0) + (if g.solved then 1 else 0)
    txt(r, string.format("%d of 5 done", n), f.bold, 13, FG, 652, 222, 132)
    for i = 1, 5 do rr(r, 652 + (i - 1) * 27, 244, 22, 8, 4, if i <= n then GREEN else LINE) end
    if g.mistakes > 0 then txt(r, string.format("Mistakes: %d", g.mistakes), f.body, 12, MUTED, 652, 282, 132) end
end

local function valveIcon(r: Renderer?, f: Art.Fonts, hits: { Hit }, x: number, y: number, key: string, open: boolean, label: string, vertical: boolean?)
    local s = 16
    local p = Path.new()
    if vertical then
        p:moveTo(Vector.xy(x - s, y - s)); p:lineTo(Vector.xy(x + s, y - s)); p:lineTo(Vector.xy(x - s, y + s)); p:lineTo(Vector.xy(x + s, y + s)); p:close()
    else
        p:moveTo(Vector.xy(x - s, y - s)); p:lineTo(Vector.xy(x + s, y + s)); p:lineTo(Vector.xy(x + s, y - s)); p:lineTo(Vector.xy(x - s, y + s)); p:close()
    end
    fill(r, p, Paint.with({ color = if open then Color.rgb(24, 30, 38) else RED }))
    fill(r, p, Paint.with({ style = "stroke", thickness = 3, color = if open then GREEN else RED, join = "round" }))
    rr(r, x - 34, y + 22, 68, 20, 10, if open then Color.rgba(84, 214, 120, 40) else Color.rgba(236, 82, 70, 50))
    txt(r, label .. (if open then " OPEN" else " SHUT"), f.bold, 11, if open then GREEN else RED, x - 34, y + 26, 68, "center")
    table.insert(hits, { x = x - 34, y = y - 30, w = 68, h = 74, action = "valve:" .. key })
end

-- Moving dots along a polyline: water that flows.
local function flowDots(r: Renderer?, pts: { number }, t: number)
    local spacing, speed = 26, 70
    local offset = (t * speed) % spacing
    for i = 1, #pts - 2, 2 do
        local ax, ay, bx, by = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
        local len = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
        local d = offset
        while d < len do
            local k = d / len
            disc(r, ax + (bx - ax) * k, ay + (by - ay) * k, 3, Color.rgb(170, 220, 255))
            d += spacing
        end
    end
end

local function pump(r: Renderer?, f: Art.Fonts, cx: number, cy: number, name: string, running: boolean, t: number)
    disc(r, cx, cy, 34, Color.rgb(36, 44, 56))
    ring(r, cx, cy, 34, if running then GREEN else RED, 3)
    local a = if running then t * 6 else 0
    for i = 0, 2 do
        local aa = a + i * math.pi * 2 / 3
        line(r, { cx, cy, cx + math.cos(aa) * 24, cy + math.sin(aa) * 24 }, if running then FG else MUTED, 4)
    end
    txt(r, name, f.bold, 13, FG, cx - 60, cy - 58, 120, "center")
    rr(r, cx - 40, cy + 40, 80, 18, 9, if running then Color.rgba(84, 214, 120, 46) else Color.rgba(236, 82, 70, 60))
    txt(r, if running then "RUNNING" else "TRIPPED", f.bold, 10.5, if running then GREEN else RED, cx - 40, cy + 43, 80, "center")
end

local function paintLineup(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    local v = g.valves
    local yIn, y1, y2 = 300, 200, 400
    local xL, xR = 130, 690
    local flowing2 = v.S2 and v.D2
    local wet1 = v.S1 or v.D1
    -- pipes: dry grey, filled blue; flowing ones carry moving dots
    local function pipe(pts: { number }, wet: boolean, flows: boolean)
        line(r, pts, if wet then WATER else DRY, 12)
        if flows then flowDots(r, pts, g.t) end
    end
    pipe({ 40, yIn, xL, yIn }, true, flowing2 or v.BYP)
    pipe({ xL, y1, xL, y2 }, true, false)
    pipe({ xL, y1, xR, y1 }, wet1, false)
    pipe({ xL, y2, xR, y2 }, true, flowing2)
    pipe({ xR, y1, xR, y2 }, true, false)
    pipe({ xR, yIn, 790, yIn }, true, flowing2)
    pipe({ xL, yIn, xR, yIn }, true, v.BYP)
    if flowing2 then flowDots(r, { xL, yIn, xL, y2 }, g.t); flowDots(r, { xR, y2, xR, yIn }, g.t) end
    txt(r, "FROM DATA HALL", f.bold, 11, MUTED, 30, yIn - 30, 120)
    txt(r, "TO CH-1", f.bold, 11, MUTED, 720, yIn - 30, 90, "right")
    pump(r, f, 410, y1, "CHWP-1", false, g.t)
    pump(r, f, 410, y2, "CHWP-2", true, g.t)
    valveIcon(r, f, hits, 260, y1, "S1", v.S1, "SUCTION")
    valveIcon(r, f, hits, 560, y1, "D1", v.D1, "DISCH.")
    valveIcon(r, f, hits, 260, y2, "S2", v.S2, "SUCTION")
    valveIcon(r, f, hits, 560, y2, "D2", v.D2, "DISCH.")
    valveIcon(r, f, hits, 300, yIn, "BYP", v.BYP, "BYPASS")
end

local function paintTower(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    -- The tower: two cells seen from above, fans spinning with their speed.
    for c = 1, 2 do
        local x, y, w, h = 70 + (c - 1) * 200, 130, 180, 200
        local online = c == 1 or g.cell2
        rr(r, x, y, w, h, 12, PANEL)
        txt(r, "CELL " .. c, f.bold, 13, if online then FG else MUTED, x, y + 12, w, "center")
        local cx, cy = x + w / 2, y + 108
        ring(r, cx, cy, 58, if online then BLUE else DRY, 3)
        local spin = if online then g.t * g.fan * 0.18 else 0
        for i = 0, 4 do
            local a = spin + i * math.pi * 2 / 5
            line(r, { cx, cy, cx + math.cos(a) * 50, cy + math.sin(a) * 50 }, if online then FG else DRY, 7)
        end
        disc(r, cx, cy, 9, if online then FG else DRY)
        if not online then
            rr(r, x + 30, y + h - 34, w - 60, 22, 11, Color.rgba(236, 82, 70, 60))
            txt(r, "OFFLINE", f.bold, 11, RED, x + 30, y + h - 29, w - 60, "center")
        end
    end
    if g.variant == 3 then
        button(r, hits, f, 70, 344, 180, 34, if g.hand then "Fans: HAND  (switch)" else "Fans: AUTO", "hand", if g.hand then "warn" else nil)
        button(r, hits, f, 270, 344, 180, 34, if g.cell2 then "Take cell 2 offline" else "Bring cell 2 online", "cell2", if g.cell2 then nil else "warn")
    elseif g.variant == 2 then
        button(r, hits, f, 270, 344, 180, 34, if g.hand then "Fans: HAND  (switch)" else "Fans: AUTO", "hand", if g.hand then "warn" else nil)
    else
        button(r, hits, f, 270, 344, 180, 34, if g.cell2 then "Take cell 2 offline" else "Bring cell 2 online", "cell2", if g.cell2 then nil else "warn")
    end
    -- Fan speed slider with - and + buttons.
    txt(r, string.format("FAN SPEED  %d %%", g.fan), f.bold, 13, FG, SLIDER_X0, SLIDER_Y - 30, 300)
    rr(r, SLIDER_X0, SLIDER_Y - 4, SLIDER_X1 - SLIDER_X0, 8, 4, LINE)
    local kx = SLIDER_X0 + (SLIDER_X1 - SLIDER_X0) * g.fan / 100
    rr(r, SLIDER_X0, SLIDER_Y - 4, kx - SLIDER_X0, 8, 4, BLUE)
    disc(r, kx, SLIDER_Y, 13, FG)
    table.insert(hits, { x = SLIDER_X0 - 16, y = SLIDER_Y - 22, w = SLIDER_X1 - SLIDER_X0 + 32, h = 44, action = "slider" })
    button(r, hits, f, 30, SLIDER_Y - 17, 50, 34, "-", "fan-")
    button(r, hits, f, 432, SLIDER_Y - 17, 50, 34, "+", "fan+")
    -- Gauge: condenser water entering CH-1, 70-100 °F.
    local gx, gy, rad = 640, 300, 120
    local lo, hi = 70, 100
    local function angle(v: number): number return math.pi + (math.clamp(v, lo, hi) - lo) / (hi - lo) * math.pi end
    local function arc(v0: number, v1: number, color: Color)
        local p = Path.new()
        local n = 24
        for i = 0, n do
            local a = angle(v0 + (v1 - v0) * i / n)
            local pt = Vector.xy(gx + math.cos(a) * rad, gy + math.sin(a) * rad)
            if i == 0 then p:moveTo(pt) else p:lineTo(pt) end
        end
        fill(r, p, Paint.with({ style = "stroke", thickness = 18, color = color }))
    end
    arc(lo, TOWER_BAND_LO, Color.rgb(60, 120, 200))
    arc(TOWER_BAND_LO, TOWER_BAND_HI, GREEN)
    arc(TOWER_BAND_HI, hi, RED)
    for _, v in { 70, 80, 86, 100 } do
        local a = angle(v)
        txt(r, tostring(v), f.mono, 11, MUTED, gx + math.cos(a) * (rad + 26) - 20, gy + math.sin(a) * (rad + 26) - 6, 40, "center")
    end
    local a = angle(g.temp)
    line(r, { gx, gy, gx + math.cos(a) * (rad - 14), gy + math.sin(a) * (rad - 14) }, FG, 5)
    disc(r, gx, gy, 10, FG)
    txt(r, string.format("%.1f °F", g.temp), f.bold, 30, FG, gx - 120, gy + 22, 240, "center")
    txt(r, "CONDENSER WATER TO CH-1", f.bold, 11, MUTED, gx - 140, gy + 60, 280, "center")
    local inBand = g.temp >= TOWER_BAND_LO and g.temp <= TOWER_BAND_HI
    local status, col
    if inBand then
        status, col = string.format("In range. Hold it: %.1f s", math.max(0, 4 - g.hold)), GREEN
    elseif g.temp > TOWER_BAND_HI then
        status, col = "Too warm: CH-1 is limiting its capacity", RED
    else
        status, col = "Too cold: CH-1 needs some lift", BLUE
    end
    txt(r, status, f.bold, 14, col, gx - 160, gy + 90, 320, "center")
    if g.flatOut > 3 then
        g.message = "The fans are flat out and it's still too warm. Is the whole tower working?"
        g.messageGood = false
    elseif g.kind == "tower" and g.message ~= nil and g.cell2 then
        g.message = nil
    end
end

local function paintBalance(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    -- The handwheel: red rim and spokes; it rotates as the valve turns (one twist = TURNS_PER_REV turns).
    local cx, cy, rad = WHEEL_X, WHEEL_Y, 110
    local a0 = g.wheelAngle
    local rim = if g.grabbed then Color.rgb(236, 64, 56) else Color.rgb(200, 40, 36)
    if g.grabbed then ring(r, cx, cy, rad + 14, Color.rgba(246, 176, 46, 90), 6) end
    ring(r, cx, cy, rad, rim, 18)
    for i = 0, 4 do
        local a = a0 + i * math.pi * 2 / 5
        line(r, { cx, cy, cx + math.cos(a) * (rad - 4), cy + math.sin(a) * (rad - 4) }, rim, 10)
    end
    disc(r, cx, cy, 24, Color.rgb(170, 30, 28))
    disc(r, cx + math.cos(a0) * rad, cy + math.sin(a0) * rad, 13, FG) -- the knob on the rim
    -- Curved arrows: clockwise closes.
    local function arc(from: number, to: number, color: Color)
        local p = Path.new()
        for k = 0, 16 do
            local a = from + (to - from) * k / 16
            local pt = Vector.xy(cx + math.cos(a) * (rad + 30), cy + math.sin(a) * (rad + 30))
            if k == 0 then p:moveTo(pt) else p:lineTo(pt) end
        end
        fill(r, p, Paint.with({ style = "stroke", thickness = 4, color = color, cap = "round" }))
        local ex, ey = cx + math.cos(to) * (rad + 30), cy + math.sin(to) * (rad + 30)
        local tx, ty = -math.sin(to) * (if to > from then 1 else -1), math.cos(to) * (if to > from then 1 else -1)
        local q = Path.new()
        q:moveTo(Vector.xy(ex + tx * 12, ey + ty * 12))
        q:lineTo(Vector.xy(ex - ty * 8, ey + tx * 8)); q:lineTo(Vector.xy(ex + ty * 8, ey - tx * 8)); q:close()
        fill(r, q, Paint.with({ color = color }))
    end
    arc(-2.4, -0.9, Color.rgba(236, 82, 70, 200))
    arc(2.4, 0.9 + math.pi * 0, Color.rgba(84, 214, 120, 160))
    txt(r, "CLOSE", f.bold, 11, RED, cx + 80, cy - 150, 60)
    txt(r, "OPEN", f.bold, 11, GREEN, cx + 84, cy + 140, 60)
    table.insert(hits, { x = cx - rad - 36, y = cy - rad - 36, w = (rad + 36) * 2, h = (rad + 36) * 2, action = "wheel" })
    txt(r, string.format("%.1f turns open (of 10)", g.turns), f.bold, 15, FG, cx - 160, cy + rad + 44, 320, "center")
    txt(r, if g.grabbed then "Twisting..." else "Grab the wheel and twist it", f.body, 12.5, if g.grabbed then AMBER else MUTED, cx - 160, cy + rad + 64, 320, "center")
    -- Fine-tuning buttons, small, to the side.
    local turnButtons: { { label: string, d: string } } = { { label = "Close 1/8", d = "-0.125" }, { label = "Open 1/8", d = "0.125" } }
    for i, b in turnButtons do
        button(r, hits, f, 400, 360 + (i - 1) * 44, 92, 34, b.label, "turn:" .. b.d)
    end
    -- The flow meter: a bar with the design band, and the reading beside it.
    local mx, my, mw, mh = 560, 130, 56, 300
    rr(r, mx, my, mw, mh, 10, PANEL)
    local function yOf(v: number): number return my + mh - mh * math.clamp(v / FLOW_MAX, 0, 1) end
    rr(r, mx - 4, yOf(FLOW_HI), mw + 8, yOf(FLOW_LO) - yOf(FLOW_HI), 4, Color.rgba(84, 214, 120, 110))
    local fy = yOf(g.flow)
    rr(r, mx + 10, fy, mw - 20, my + mh - fy, 6, BLUE)
    line(r, { mx - 10, yOf(FLOW_DESIGN), mx + mw + 10, yOf(FLOW_DESIGN) }, GREEN, 2)
    for _, v in { 0, 500, 1000, 1500, 2000 } do -- scale marks
        txt(r, tostring(v), f.mono, 11, MUTED, mx - 54, yOf(v) - 7, 46, "right")
    end
    local col = 636
    local cw = Games.W - col - 24
    txt(r, string.format("%d gpm", math.round(g.flow)), f.bold, 30, FG, col, 140, cw)
    txt(r, "CONDENSER WATER FLOW", f.bold, 11, MUTED, col, 180, cw)
    local status, sc
    if g.flow >= FLOW_LO and g.flow <= FLOW_HI then
        status, sc = string.format("On design. Hold it: %.1f s", math.max(0, 3 - g.hold)), GREEN
    elseif g.flow > FLOW_HI then
        status, sc = "Too much flow: twist it clockwise (close)", RED
    else
        status, sc = "Too little flow: twist it back (open)", BLUE
    end
    local ly = 210
    for _, l in wrap(f.bold, status, 14, cw) do
        txt(r, l, f.bold, 14, sc, col, ly, cw)
        ly += 19
    end
    rr(r, col, 330, cw, 60, 10, Color.rgba(255, 255, 255, 14))
    txt(r, "BALANCING REPORT", f.bold, 10.5, MUTED, col + 12, 340, cw - 24)
    txt(r, "CH-1 condenser:", f.body, 13, FG, col + 12, 358, cw - 24)
    txt(r, string.format("%d gpm", FLOW_DESIGN), f.bold, 13, GREEN, col + 12, 374, cw - 24)
end

local function toolIcon(r: Renderer?, kind: string, cx: number, cy: number, color: Color)
    if kind == "look" then
        local p = Path.new()
        p:moveTo(Vector.xy(cx - 14, cy)); p:cubicTo(Vector.xy(cx - 6, cy - 10), Vector.xy(cx + 6, cy - 10), Vector.xy(cx + 14, cy))
        p:cubicTo(Vector.xy(cx + 6, cy + 10), Vector.xy(cx - 6, cy + 10), Vector.xy(cx - 14, cy)); p:close()
        fill(r, p, Paint.with({ style = "stroke", thickness = 2.5, color = color }))
        disc(r, cx, cy, 4, color)
    elseif kind == "temp" then
        rr(r, cx - 3.5, cy - 13, 7, 18, 3.5, color)
        disc(r, cx, cy + 8, 6, color)
    else
        local p = Path.new()
        p:moveTo(Vector.xy(cx - 6, cy + 10)); p:cubicTo(Vector.xy(cx - 16, cy - 2), Vector.xy(cx - 6, cy - 14), Vector.xy(cx + 2, cy - 12))
        p:cubicTo(Vector.xy(cx + 12, cy - 10), Vector.xy(cx + 12, cy + 2), Vector.xy(cx + 4, cy + 4))
        p:cubicTo(Vector.xy(cx, cy + 6), Vector.xy(cx + 2, cy + 12), Vector.xy(cx - 6, cy + 10))
        fill(r, p, Paint.with({ style = "stroke", thickness = 2.5, color = color, join = "round" }))
    end
end

local function gaugeFace(r: Renderer?, cx: number, cy: number, rad: number, frac: number)
    disc(r, cx, cy, rad, Color.rgb(236, 238, 240))
    ring(r, cx, cy, rad, Color.rgb(90, 96, 104), 3)
    local a = math.pi * (0.75 + 1.5 * frac)
    line(r, { cx, cy, cx + math.cos(a) * rad * 0.8, cy + math.sin(a) * rad * 0.8 }, Color.rgb(200, 40, 36), 2.5)
    disc(r, cx, cy, 3, INK)
end

local LABELS: { [string]: { number } } = { -- where each part's name tag sits
    suction = { 74, 198 }, discharge = { 322, 170 }, casing = { 170, 300 }, seal = { 252, 346 }, coupling = { 331, 300 }, motor = { 446, 300 },
}

local function pill(r: Renderer?, f: Art.Fonts, cx: number, cy: number, label: string, bg: Color, fg: Color)
    local w = Art.measure(f.bold, label, 12.5) + 20
    rr(r, cx - w / 2, cy - 12, w, 24, 12, bg)
    txt(r, label, f.bold, 12.5, fg, cx - w / 2 + 10, cy - 7, w - 20, "center")
end

local function paintInspect(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    -- The pump, side view: suction pipe in, casing, seal, bearing frame, coupling guard, motor.
    local STEEL, TEAL, MOTOR = Color.rgb(150, 156, 164), Color.rgb(38, 118, 108), Color.rgb(36, 72, 150)
    rr(r, 50, 372, 500, 22, 4, Color.rgb(110, 114, 120)) -- base
    txt(r, "CHWP-1", f.bold, 13, FG, 60, 376, 200)
    rr(r, 24, 280, 110, 40, 4, STEEL) -- suction pipe
    line(r, { 74, 280, 74, 254 }, STEEL, 6)
    gaugeFace(r, 74, 236, 20, 0.3)
    rr(r, 150, 130, 40, 120, 4, STEEL) -- discharge pipe
    line(r, { 190, 170, 214, 170 }, STEEL, 6)
    gaugeFace(r, 236, 170, 22, 0.3)
    disc(r, 170, 300, 58, TEAL) -- volute
    ring(r, 170, 300, 40, Color.rgb(28, 92, 84), 4)
    rr(r, 228, 284, 36, 32, 4, Color.rgb(120, 126, 134)) -- seal housing
    rr(r, 262, 280, 40, 40, 4, STEEL) -- bearing frame
    rr(r, 300, 266, 62, 68, 8, Color.rgb(236, 180, 30)) -- coupling guard
    rr(r, 362, 240, 160, 120, 14, MOTOR) -- motor
    for i = 0, 6 do line(r, { 376 + i * 20, 250, 376 + i * 20, 350 }, Color.rgb(28, 58, 124), 4) end
    rr(r, 520, 252, 22, 96, 8, Color.rgb(30, 60, 128)) -- fan cover
    rr(r, 400, 214, 80, 22, 4, Color.rgb(196, 200, 204)) -- terminal box
    for _, x in { 120, 220, 380, 500 } do rr(r, x, 350, 26, 24, 3, Color.rgb(90, 94, 100)) end -- feet
    -- Every part: a ring and a name tag. Selected = amber; checked = green (a clue) or grey (normal).
    local pulse = 0.5 + 0.5 * math.sin(g.t * 3)
    for _, p in PARTS do
        local done, sel = g.checked[p.key], g.part == p.key
        if sel then
            ring(r, p.x, p.y, p.rad, AMBER, 4)
        elseif not done then
            ring(r, p.x, p.y, p.rad, Color.rgba(255, 255, 255, math.round(60 + 80 * pulse)), 2)
        end
        local lp = LABELS[p.key]
        local bg = if sel then AMBER elseif done and p.clue ~= nil then GREEN elseif done then Color.rgb(84, 92, 104) else Color.rgba(12, 16, 22, 225)
        pill(r, f, lp[1], lp[2], p.name, bg, if sel or (done and p.clue ~= nil) then INK else FG)
        table.insert(hits, { x = p.x - p.rad, y = p.y - p.rad, w = p.rad * 2, h = p.rad * 2, action = "part:" .. p.key })
        table.insert(hits, { x = lp[1] - 60, y = lp[2] - 12, w = 120, h = 24, action = "part:" .. p.key })
    end
    -- Clue board.
    local bx, by, bw = 580, 120, 216
    rr(r, bx, by, bw, 274, 12, PANEL)
    txt(r, string.format("CLUES IT FAILED  %d / %d", cluesFound(g), CLUES), f.bold, 12, AMBER, bx + 14, by + 14, bw - 28)
    local ly = by + 42
    for _, p in PARTS do
        if p.clue ~= nil and g.checked[p.key] then
            disc(r, bx + 22, ly + 8, 6, GREEN)
            txt(r, p.clue :: string, f.bold, 13.5, FG, bx + 36, ly, bw - 50)
            ly += 26
        end
    end
    for _ = cluesFound(g) + 1, CLUES do
        ring(r, bx + 22, ly + 8, 6, MUTED, 1.5)
        txt(r, "?", f.bold, 13.5, MUTED, bx + 36, ly, bw - 50)
        ly += 26
    end
    if g.mistakes > 0 then
        txt(r, string.format("Wrong checks: %d", g.mistakes), f.body, 12, MUTED, bx + 14, by + 246, bw - 28)
    end
    -- Step prompt: 1 pick a part, 2 choose how to check it.
    local part: Part? = nil
    for _, p in PARTS do if p.key == g.part then part = p end end
    if part == nil then
        rr(r, 24, 410, 772, 52, 12, Color.rgba(70, 160, 255, 30))
        disc(r, 50, 436, 13, BLUE)
        txt(r, "1", f.bold, 14, INK, 37, 428, 26, "center")
        txt(r, "Click a part of the pump (the labels) to check it.", f.bold, 15, FG, 74, 426, 700)
    else
        rr(r, 24, 410, 772, 52, 12, Color.rgba(246, 176, 46, 30))
        disc(r, 50, 436, 13, AMBER)
        txt(r, "2", f.bold, 14, INK, 37, 428, 26, "center")
        txt(r, "How do you check the " .. string.lower(part.name) .. "?", f.bold, 15, FG, 74, 426, 270)
        local tools = { { key = "look", label = "Look" }, { key = "temp", label = "Temperature" }, { key = "listen", label = "Listen" } }
        for i, t in tools do
            local x, y, w, h = 350 + (i - 1) * 148, 417, 138, 38
            rr(r, x, y, w, h, h / 2, Color.rgb(48, 56, 68))
            toolIcon(r, t.key, x + 24, y + h / 2, FG)
            txt(r, t.label, f.bold, 14, FG, x + 42, y + 11, w - 52)
            table.insert(hits, { x = x, y = y, w = w, h = h, action = "tool:" .. t.key })
        end
    end
end

-- A drive's display: four lines of what its current screen shows.
local function driveScreen(g: Game): { string }
    local blink = math.floor(g.t * 2) % 2 == 0
    if g.drive == 1 then
        if g.screen == "faults" then return { "FAULT LOG  1/1", "F005  MOTOR OVERLOAD", "07:42 TODAY", "NEXT = DETAILS" } end
        if g.screen == "detail" then return { "F005  DETAILS", "CURRENT AT TRIP 132 %", "LIMIT           115 %", "BACK = HOME" } end
        if g.screen == "status" then return { "STATUS: TRIPPED", "OUTPUT     0.0 Hz", "MOTOR        0 A", "RUN CMD    AUTO" } end
        return { "CHWP-1 DRIVE", if blink then "*** FAULT ***" else "", "0.0 Hz      0 A", "FAULT LOG = WHY" }
    end
    if g.screen == "faults" then return { "FAULT LOG", "NO FAULTS", "", "BACK = HOME" } end
    if g.screen == "status" then return { "STATUS: RUNNING", "OUTPUT    52.0 Hz", "MOTOR       71 A", "START: AUTO STANDBY" } end
    return { "CHWP-2 DRIVE", "RUNNING", "52.0 Hz     71 A", "STARTED 07:42 AUTO" }
end

local function paintDrive(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    -- Drive tabs.
    for d = 1, 2 do
        local x, y, w, h = 40 + (d - 1) * 200, 112, 190, 34
        local on = g.drive == d
        rr(r, x, y, w, h, 10, if on then AMBER else Color.rgb(48, 56, 68))
        txt(r, string.format("Drive %d · CHWP-%d", d, d), f.bold, 14, if on then INK else FG, x, y + 9, w, "center")
        table.insert(hits, { x = x, y = y, w = w, h = h, action = "drv:" .. d })
    end
    -- Faceplate: display and keypad.
    rr(r, 40, 156, 390, 300, 16, Color.rgb(44, 48, 56))
    rr(r, 60, 172, 350, 126, 8, Color.rgb(10, 26, 18))
    local fault = g.drive == 1
    for i, l in driveScreen(g) do
        txt(r, l, f.mono, 16, if fault and i == 2 then Color.rgb(255, 110, 90) else Color.rgb(110, 240, 150), 76, 182 + (i - 1) * 27, 320)
    end
    local keys = {
        { "FAULT LOG", "key:fault", 60, 314 }, { "STATUS", "key:status", 181, 314 }, { "NEXT", "key:next", 302, 314 },
        { "BACK", "key:back", 60, 378 }, { "RESET", "key:reset", 302, 378 },
    }
    for _, k in keys do
        local label, action, x, y = k[1] :: string, k[2] :: string, k[3] :: number, k[4] :: number
        rr(r, x, y, 108, 48, 10, if action == "key:reset" then Color.rgb(170, 40, 34) else Color.rgb(70, 78, 92))
        txt(r, label, f.bold, 14, FG, x, y + 16, 108, "center")
        table.insert(hits, { x = x, y = y, w = 108, h = 48, action = action })
    end
    -- The questions, ticked as they're answered, with a hint for each open one.
    local bx, by, bw = 460, 112, 336
    rr(r, bx, by, bw, 344, 12, PANEL)
    txt(r, "FIND OUT", f.bold, 12, AMBER, bx + 16, by + 14, bw - 32)
    local items = {
        { key = "code", q = "Why did Drive 1 stop?", a = "F005: motor overload", hint = "Drive 1, then FAULT LOG" },
        { key = "current", q = "How hard was the motor working?", a = "132 % current (limit 115 %)", hint = "Drive 1, FAULT LOG, then NEXT" },
        { key = "standby", q = "Which pump is running now?", a = "CHWP-2, started automatically", hint = "Look at Drive 2" },
    }
    local y = by + 44
    for i, it in items do
        local done = g.found[it.key] == true
        if done then disc(r, bx + 28, y + 9, 10, GREEN) else ring(r, bx + 28, y + 9, 10, MUTED, 2) end
        txt(r, tostring(i), f.bold, 12, if done then INK else MUTED, bx + 18, y + 2, 20, "center")
        txt(r, it.q, f.bold, 14.5, FG, bx + 48, y, bw - 64)
        txt(r, if done then it.a else "Hint: " .. it.hint, if done then f.bold else f.body, 13, if done then GREEN else MUTED, bx + 48, y + 22, bw - 64)
        y += 70
    end
    if g.mistakes > 0 then txt(r, string.format("Resets pressed: %d", g.mistakes), f.body, 12, MUTED, bx + 16, by + 316, bw - 32) end
end

local function valveTypeIcon(r: Renderer?, k: string, cx: number, cy: number)
    local body = Color.rgb(120, 126, 136)
    line(r, { cx - 22, cy + 8, cx + 22, cy + 8 }, body, 8)
    rr(r, cx - 9, cy - 2, 18, 20, 4, body)
    if k == "mot" then
        rr(r, cx - 12, cy - 22, 24, 18, 3, Color.rgb(60, 110, 200))
        line(r, { cx, cy - 4, cx, cy - 2 }, body, 4)
    elseif k == "byp" then
        local p = Path.new()
        p:moveTo(Vector.xy(cx - 16, cy + 2)); p:cubicTo(Vector.xy(cx - 16, cy - 22), Vector.xy(cx + 16, cy - 22), Vector.xy(cx + 16, cy + 2))
        fill(r, p, Paint.with({ style = "stroke", thickness = 4, color = BLUE, cap = "round" }))
    elseif k == "chk" then
        -- a flap and a one-way arrow
        local p = Path.new()
        p:moveTo(Vector.xy(cx - 6, cy - 22)); p:lineTo(Vector.xy(cx + 8, cy - 16)); p:lineTo(Vector.xy(cx - 6, cy - 10)); p:close()
        fill(r, p, Paint.with({ color = GREEN }))
        line(r, { cx - 18, cy - 16, cx - 6, cy - 16 }, GREEN, 3)
    elseif k == "rlf" then
        -- a spring on top, and an arrow venting upward
        line(r, { cx, cy - 2, cx - 5, cy - 6, cx + 5, cy - 10, cx - 5, cy - 14, cx + 5, cy - 18, cx, cy - 22 }, AMBER, 2.5)
        line(r, { cx + 12, cy - 6, cx + 12, cy - 24 }, RED, 3)
        line(r, { cx + 7, cy - 19, cx + 12, cy - 25, cx + 17, cy - 19 }, RED, 3)
    elseif k == "suc" then
        disc(r, cx + 26, cy + 8, 11, Color.rgb(38, 118, 108))
        line(r, { cx, cy - 2, cx, cy - 14 }, body, 3)
        ring(r, cx, cy - 16, 8, Color.rgb(200, 40, 36), 3)
    else
        line(r, { cx, cy - 2, cx, cy - 14 }, body, 3)
        ring(r, cx, cy - 16, 9, if k == "bal" then Color.rgb(60, 120, 220) else Color.rgb(200, 40, 36), 3)
        if k == "bal" then disc(r, cx + 12, cy - 4, 4, AMBER) end
    end
end

local function paintMatch(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    local order = { "iso", "bal", "mot", "byp", "suc", "chk", "rlf" }
    if #g.jobOrder < 7 then order = { "iso", "bal", "mot", "byp", "suc" } end
    local step, bh = if #order > 5 then 46 else 62, if #order > 5 then 40 else 54
    local vy: { [string]: number } = {}
    local jy: { [string]: number } = {}
    local shake = if g.t - g.wrongAt < 0.35 then math.sin((g.t - g.wrongAt) * 60) * 4 else 0
    for i, k in order do
        local y = 112 + (i - 1) * step
        vy[k] = y + bh / 2
        local done, sel = g.matched[k] == true, g.selValve == k
        rr(r, 24 + (if sel then shake else 0), y, 260, bh, 12, if done then Color.rgba(84, 214, 120, 40) elseif sel then Color.rgba(246, 176, 46, 70) else PANEL)
        valveTypeIcon(r, k, 64, y + bh / 2)
        txt(r, VALVE_TYPES[k].name, f.bold, 15, if done then GREEN else FG, 104, y + bh / 2 - 9, 170)
        if not done then table.insert(hits, { x = 24, y = y, w = 260, h = bh, action = "mv:" .. k }) end
    end
    for i, k in g.jobOrder do
        local y = 112 + (i - 1) * step
        jy[k] = y + bh / 2
        local done = g.matched[k] == true
        rr(r, 340, y, 456, bh, 12, if done then Color.rgba(84, 214, 120, 40) else Color.rgb(40, 48, 58))
        local ly = y + (if #wrap(f.body, VALVE_TYPES[k].job, 14, 420) > 1 then bh / 2 - 18 else bh / 2 - 9)
        for _, l in wrap(f.body, VALVE_TYPES[k].job, 14, 420) do
            txt(r, l, f.body, 14, if done then GREEN else FG, 358, ly, 420)
            ly += 18
        end
        if not done then table.insert(hits, { x = 340, y = y, w = 456, h = bh, action = "mj:" .. k }) end
    end
    for _, k in order do
        if g.matched[k] then line(r, { 284, vy[k], 340, jy[k] }, GREEN, 3) end
    end
    local n = 0
    for _ in g.matched do n += 1 end
    local fy = 112 + #order * step + 4
    txt(r, string.format("%d of %d matched", n, #order), f.bold, 13, MUTED, 24, fy, 160)
    if g.selValve ~= nil then txt(r, "Now click its job on the right", f.bold, 13, AMBER, 340, fy, 300) end
end

local function paintIsolate(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    local v = g.valves
    local need = isolateNeeds(g)
    local evapIso = not v.CHWR and not v.CHWS
    local condIso = not v.CWS and not v.CWR
    local targetEvap, targetCond = g.job ~= "cond", g.job ~= "evap"
    local CHW, CW = Color.rgb(50, 120, 230), Color.rgb(50, 170, 90)
    local pulse = 0.5 + 0.5 * math.sin(g.t * 4)
    -- The work order card.
    rr(r, 24, 98, 230, 330, 12, Color.rgb(236, 232, 214))
    rr(r, 24, 98, 230, 34, 12, AMBER)
    txt(r, "WORK ORDER", f.bold, 13, INK, 24, 108, 230, "center")
    local job = if g.job == "both" then "Annual teardown of CH-1." elseif g.job == "cond" then "Clean CH-1's condenser tubes." else "Inspect CH-1's evaporator tubes."
    local ly = 146
    for _, l in wrap(f.bold, job, 15, 200) do txt(r, l, f.bold, 15, INK, 40, ly, 200); ly += 20 end
    ly += 8
    txt(r, "ISOLATE:", f.bold, 11, Color.rgb(90, 84, 70), 40, ly, 200); ly += 16
    txt(r, string.upper(isolatePart(g)), f.bold, 20, Color.rgb(170, 40, 34), 40, ly, 200); ly += 34
    -- Steps, ticked as you go.
    local closedAll, taggedAll = true, true
    for k in need do
        if v[k] then closedAll = false end
        if not g.tagged[k] then taggedAll = false end
    end
    local nNeed = 0
    for _ in need do nNeed += 1 end
    local steps = {
        { string.format("Close its %d valves", nNeed), closedAll },
        { "Lock and tag each one", taggedAll },
    }
    for i, st in steps do
        local done = st[2] :: boolean
        local current = not done and (i == 1 or (steps[i - 1][2] :: boolean))
        if done then disc(r, 50, ly + 9, 9, GREEN) else ring(r, 50, ly + 9, 9, if current then AMBER else Color.rgb(140, 134, 120), 2.5) end
        txt(r, tostring(i), f.bold, 11, if done then INK else Color.rgb(90, 84, 70), 41, ly + 3, 18, "center")
        txt(r, st[1] :: string, f.bold, 14, if current then INK else Color.rgb(90, 84, 70), 66, ly + 1, 180)
        ly += 30
    end
    ly += 6
    txt(r, "Leave everything else open.", f.body, 12.5, Color.rgb(90, 84, 70), 40, ly, 200)
    -- Legend.
    rr(r, 40, 390, 14, 6, 3, CHW); txt(r, "chilled water", f.body, 12, Color.rgb(60, 56, 46), 60, 384, 90)
    rr(r, 150, 390, 14, 6, 3, CW); txt(r, "condenser water", f.body, 12, Color.rgb(60, 56, 46), 170, 384, 90)

    -- The diagram (shifted right of the card).
    local ox = 272
    local function X(x: number): number return ox + (x - 40) * 0.68 end
    local function pipe(x0: number, x1: number, y: number, wet: boolean, col: Color, flows: boolean)
        line(r, { X(x0), y, X(x1), y }, if wet then col else DRY, 11)
        if flows then flowDots(r, { X(x0), y, X(x1), y }, g.t) end
    end
    local yE, yC = 186, 346
    pipe(40, 170, yE, true, CHW, not evapIso); pipe(170, 300, yE, not evapIso, CHW, not evapIso)
    pipe(520, 650, yE, not evapIso, CHW, not evapIso); pipe(650, 780, yE, true, CHW, not evapIso)
    pipe(40, 170, yC, true, CW, not condIso); pipe(170, 300, yC, not condIso, CW, not condIso)
    pipe(520, 650, yC, not condIso, CW, not condIso); pipe(650, 780, yC, true, CW, not condIso)
    -- The chiller: the part to isolate pulses amber until it's cut off.
    local function shell(y: number, name: string, sub: string, iso: boolean, target: boolean, col: Color)
        if target and not iso then rr(r, X(296), y - 4, (X(524) - X(296)), 120, 16, Color.rgba(246, 176, 46, math.round(60 + 120 * pulse))) end
        rr(r, X(300), y, X(520) - X(300), 112, 14, if iso then Color.rgb(60, 66, 76) else col)
        txt(r, name, f.bold, 15, FG, X(300), y + 30, X(520) - X(300), "center")
        txt(r, if iso then "ISOLATED: no water" elseif target then "TO ISOLATE" else sub, f.bold, 11.5,
            if iso then AMBER elseif target then Color.rgb(255, 220, 140) else MUTED, X(300), y + 54, X(520) - X(300), "center")
        if iso and target then
            disc(r, X(520) - 18, y + 18, 11, GREEN)
            line(r, { X(520) - 24, y + 18, X(520) - 19, y + 23, X(520) - 11, y + 13 }, INK, 2.5)
        end
    end
    shell(yE - 56, "EVAPORATOR", "chilled water: leave it", evapIso, targetEvap, Color.rgb(36, 72, 150))
    shell(yC - 56, "CONDENSER", "condenser water: leave it", condIso, targetCond, Color.rgb(30, 110, 70))
    txt(r, "CH-1  (OFF)", f.bold, 12, MUTED, X(300), 252, X(520) - X(300), "center")
    -- Valves: a big handwheel each; closed ones turn red, then carry a lock and tag.
    local function valve(x: number, y: number, key: string)
        local cx = X(x)
        local open = v[key]
        local shake = if g.wrongValve == key and g.t - g.wrongAt < 0.4 then math.sin((g.t - g.wrongAt) * 60) * 4 else 0
        cx += shake
        disc(r, cx, y, 22, Color.rgb(28, 32, 40))
        ring(r, cx, y, 19, if open then Color.rgb(200, 204, 210) else RED, 5)
        local a0 = if open then 0 else math.pi / 4
        for i = 0, 2 do
            local a = a0 + i * math.pi * 2 / 3
            line(r, { cx, y, cx + math.cos(a) * 17, y + math.sin(a) * 17 }, if open then Color.rgb(200, 204, 210) else RED, 3)
        end
        local lab = if g.tagged[key] then "LOCKED" elseif open then "OPEN" else "CLOSED"
        rr(r, cx - 36, y + 26, 72, 20, 10, if g.tagged[key] then Color.rgba(246, 176, 46, 70) elseif open then Color.rgba(255, 255, 255, 20) else Color.rgba(236, 82, 70, 60))
        txt(r, key .. " " .. lab, f.bold, 10.5, if g.tagged[key] then AMBER elseif open then FG else RED, cx - 36, y + 30, 72, "center")
        if g.tagged[key] then
            rr(r, cx + 12, y - 30, 22, 20, 4, Color.rgb(220, 60, 40))
            ring(r, cx + 23, y - 32, 6, Color.rgb(200, 204, 210), 2.5)
            rr(r, cx - 30, y - 34, 26, 30, 3, WHITE_TAG); rr(r, cx - 30, y - 34, 26, 9, 3, RED)
        elseif not open and closedAll and need[key] then
            ring(r, cx, y, 27 + 3 * pulse, AMBER, 2.5) -- click me: lock and tag
        end
        if g.wrongValve == key and g.t - g.wrongAt < 1.6 then
            rr(r, cx - 52, y - 56, 104, 22, 11, RED)
            txt(r, "Not this one", f.bold, 11, FG, cx - 52, y - 51, 104, "center")
        end
        table.insert(hits, { x = cx - 36, y = y - 30, w = 72, h = 78, action = "valve:" .. key })
    end
    valve(170, yE, "CHWR"); valve(650, yE, "CHWS"); valve(170, yC, "CWS"); valve(650, yC, "CWR")
    txt(r, "from data hall", f.body, 11, MUTED, X(40), yE - 26, 100)
    txt(r, "to data hall", f.body, 11, MUTED, X(780) - 100, yE - 26, 100, "right")
    txt(r, "from tower", f.body, 11, MUTED, X(40), yC + 18, 100)
    txt(r, "to tower", f.body, 11, MUTED, X(780) - 100, yC + 18, 100, "right")
end

local function paintSpot(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    local c = g.ctx
    local rows = c.readings or {}
    -- The countdown bar: 10 s to answer for the bonus (it's a race, but it never fails you).
    local limit = if Games.round >= 2 then 7 else 10
    local left = math.max(0, limit - g.t)
    rr(r, 24, 104, 772, 8, 4, LINE)
    rr(r, 24, 104, 772 * left / limit, 8, 4, if left > 4 then GREEN elseif left > 0 then AMBER else RED)
    local combo = c.combo or 0
    if combo >= 2 then
        rr(r, 676, 120, 120, 26, 13, Color.rgba(246, 176, 46, 60))
        txt(r, string.format("COMBO x%d", combo), f.bold, 13, AMBER, 676, 126, 120, "center")
    end
    for i, rd in rows do
        local x, y, w, h = 24 + ((i - 1) % 2) * 392, 156 + math.floor((i - 1) / 2) * 116, 380, 104
        rr(r, x, y, w, h, 12, PANEL)
        txt(r, rd.label, f.bold, 13, MUTED, x + 16, y + 12, w - 32)
        if rd.text ~= nil then
            txt(r, rd.text, f.bold, 26, FG, x + 16, y + 40, w - 32)
        else
            local lo, hi, mn, mx = rd.lo, rd.hi, rd.min, rd.max
            local bx, by, bw = x + 16, y + 74, w - 32
            local function px(v: number): number return bx + bw * math.clamp((v - mn) / (mx - mn), 0, 1) end
            rr(r, bx, by, bw, 10, 5, LINE)
            rr(r, px(lo), by, px(hi) - px(lo), 10, 5, Color.rgba(84, 214, 120, 150))
            local vx = px(rd.value)
            line(r, { vx, by - 8, vx, by + 18 }, FG, 4)
            txt(r, string.format("%s %s", rd.fmt or tostring(rd.value), rd.unit or ""), f.bold, 26, FG, x + 16, y + 34, w - 32)
            txt(r, string.format("normal %s-%s", tostring(lo), tostring(hi)), f.body, 11.5, MUTED, x + w - 150, y + 14, 134, "right")
        end
    end
    local by = 156 + math.ceil(#rows / 2) * 116 + 4
    if g.stage == "decide" then
        button(r, hits, f, 24, by, 376, 46, "Looks normal", "normal", "primary")
        button(r, hits, f, 420, by, 376, 46, "Something's wrong", "problem", "warn")
    else
        txt(r, "What's wrong?", f.bold, 15, AMBER, 24, by - 2, 300)
        for i, fnd in c.findings or {} do
            button(r, hits, f, 24 + (i - 1) * 260, by + 22, 250, 40, fnd, "finding:" .. i)
        end
    end
end

local function paintEvidence(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    local c = g.ctx
    txt(r, "CLUES  (click to pin)", f.bold, 11, MUTED, 24, 104, 300)
    for i, cl in c.clues do
        local y = 124 + (i - 1) * 56
        local on = g.pinned[i] == true
        rr(r, 24, y, 370, 48, 10, if on then Color.rgba(246, 176, 46, 60) else PANEL)
        if on then disc(r, 44, y + 24, 8, AMBER) else ring(r, 44, y + 24, 8, MUTED, 2) end
        local ly = y + (if #wrap(f.bold, cl.text, 13.5, 320) > 1 then 7 else 15)
        for _, l in wrap(f.bold, cl.text, 13.5, 320) do
            txt(r, l, f.bold, 13.5, FG, 62, ly, 320)
            ly += 17
        end
        table.insert(hits, { x = 24, y = y, w = 370, h = 48, action = "pin:" .. i })
    end
    txt(r, "CONCLUSION  (pick one)", f.bold, 11, MUTED, 420, 104, 300)
    txt(r, c.question or "", f.bold, 15, FG, 420, 124, 376)
    for i, ch in c.choices do
        local y = 154 + (i - 1) * 64
        local on = g.pick == i
        rr(r, 420, y, 376, 56, 10, if on then Color.rgba(70, 160, 255, 70) else Color.rgb(40, 48, 58))
        local ly = y + (if #wrap(f.bold, ch.label, 13.5, 340) > 1 then 11 else 19)
        for _, l in wrap(f.bold, ch.label, 13.5, 340) do
            txt(r, l, f.bold, 13.5, FG, 438, ly, 340)
            ly += 17
        end
        table.insert(hits, { x = 420, y = y, w = 376, h = 56, action = "pick:" .. i })
    end
end

local function paintContain(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    -- Top-down floor: the pump that leaks, the puddle, the MCC to the east, the walkway to the south.
    local cx, cy = 300, 290
    rr(r, 24, 104, 600, 370, 12, Color.rgb(54, 58, 64))
    for i = 0, 5 do line(r, { 24 + i * 120, 104, 24 + i * 120, 474 }, Color.rgb(62, 66, 72), 2) end
    rr(r, cx - 50, cy - 178, 100, 60, 8, Color.rgb(38, 118, 108))
    txt(r, "LEAKING PUMP", f.bold, 11, FG, cx - 50, cy - 155, 100, "center")
    -- The electrical side.
    rr(r, cx + 200, cy - 80, 110, 160, 8, Color.rgb(70, 76, 86))
    rr(r, cx + 200, cy - 80, 110, 26, 8, Color.rgb(236, 180, 30))
    txt(r, "MCC 480 V", f.bold, 12, INK, cx + 200, cy - 74, 110, "center")
    local danger = math.max(g.radii[1], g.radii[2] * 0.85, g.radii[8] * 0.85)
    if danger > 140 and not g.solved then
        rr(r, cx + 196, cy - 84, 118, 168, 10, Color.rgba(236, 82, 70, math.round(60 + 60 * math.sin(g.t * 10))))
    end
    -- The walkway.
    rr(r, 40, 436, 560, 30, 6, if g.signed then Color.rgba(246, 176, 46, 90) else Color.rgba(246, 176, 46, 36))
    txt(r, if g.signed then "WALKWAY  ·  wet-floor sign placed" else "WALKWAY  (click to place a wet-floor sign)", f.bold, 12, AMBER, 40, 444, 560, "center")
    if not g.signed then table.insert(hits, { x = 40, y = 436, w = 560, h = 30, action = "sign" }) end
    -- The puddle: a blob through its eight radii.
    local p = Path.new()
    for i = 0, 16 do
        local k = i % 8
        local a = k * math.pi / 4
        local rad = g.radii[k + 1]
        local pt = Vector.xy(cx + math.cos(a) * rad, cy + math.sin(a) * rad * 0.8)
        if i == 0 then p:moveTo(pt) else p:lineTo(pt) end
    end
    p:close()
    fill(r, p, Paint.with({ color = Color.rgba(60, 130, 220, 200) }))
    -- Drips from the pump.
    local d = (g.t * 1.6) % 1
    disc(r, cx, cy - 116 + d * 90, 4, Color.rgb(140, 190, 255))
    -- Sock spots: eight places around the puddle.
    for i = 1, 8 do
        local a = (i - 1) * math.pi / 4
        local sx, sy = cx + math.cos(a) * 118, cy + math.sin(a) * 118 * 0.8
        if g.socks[i] then
            local q = Path.new()
            q:moveTo(Vector.xy(sx - math.sin(a) * 30, sy + math.cos(a) * 24)); q:lineTo(Vector.xy(sx + math.sin(a) * 30, sy - math.cos(a) * 24))
            fill(r, q, Paint.with({ style = "stroke", thickness = 14, color = Color.rgb(246, 196, 24), cap = "round" }))
        else
            ring(r, sx, sy, 16, Color.rgba(255, 255, 255, math.round(110 + 80 * math.sin(g.t * 4 + i))), 2.5)
            txt(r, "+", f.bold, 16, FG, sx - 10, sy - 10, 20, "center")
            table.insert(hits, { x = sx - 22, y = sy - 22, w = 44, h = 44, action = "sock:" .. i })
        end
    end
    -- Checklist and report.
    local n = 0
    for i = 1, 8 do if g.socks[i] then n += 1 end end
    rr(r, 640, 104, 156, 370, 12, PANEL)
    txt(r, "TO DO", f.bold, 11, AMBER, 652, 116, 132)
    local items = { { string.format("Absorbent socks %d/8", n), n == 8 }, { "Wet-floor sign", g.signed }, { "Report it", g.reported } }
    for i, it in items do
        local y = 142 + (i - 1) * 30
        if it[2] then disc(r, 662, y + 8, 7, GREEN) else ring(r, 662, y + 8, 7, MUTED, 2) end
        txt(r, it[1] :: string, f.bold, 13, if it[2] then GREEN else FG, 676, y, 116)
    end
    if not g.reported then button(r, hits, f, 652, 240, 132, 38, "Report it", "report", "primary") end
    if g.mistakes > 0 then txt(r, string.format("Spills: %d", g.mistakes), f.body, 12, MUTED, 652, 448, 132) end
end

local function paintSolved(r: Renderer?, f: Art.Fonts, g: Game, hits: { Hit })
    local k = math.clamp((g.t - g.solvedAt - 0.5) / 0.3, 0, 1)
    if k <= 0 then return end
    rr(r, 0, 0, Games.W, Games.H, 18, Color.rgba(10, 14, 18, math.round(200 * k)))
    local w, h = 460, 290
    local x, y = (Games.W - w) / 2, (Games.H - h) / 2
    rr(r, x, y, w, h, 18, Color.rgb(28, 34, 42))
    txt(r, "SOLVED!", f.bold, 30, GREEN, x, y + 22, w, "center")
    for i = 1, 3 do
        if r ~= nil then UI.star(r, x + w / 2 + (i - 2) * 56, y + 116, if i == 2 then 26 else 22, if i <= g.stars then AMBER else Color.rgba(255, 255, 255, 34)) end
    end
    local ly = y + 152
    for _, l in wrap(f.body, g.summary, 15, w - 60) do
        txt(r, l, f.body, 15, FG, x + 30, ly, w - 60, "center")
        ly += 20
    end
    local medal = if g.stars >= 3 then "GOLD" elseif g.stars == 2 then "SILVER" else "BRONZE"
    local mc = if g.stars >= 3 then AMBER elseif g.stars == 2 then Color.rgb(200, 206, 214) else Color.rgb(205, 127, 50)
    rr(r, x + w / 2 - 50, y + 60, 100, 20, 10, mc)
    txt(r, medal, f.bold, 11, INK, x + w / 2 - 50, y + 64, 100, "center")
    txt(r, string.format("+%d points  ·  %s", g.stars, clock(g.solvedAt)), f.bold, 15, AMBER, x, ly + 6, w, "center")
    button(r, hits, f, x + w / 2 - 90, y + h - 58, 180, 40, "Continue", "finish", "primary")
end

-- Paints the whole panel; returns its hit regions.
function Games.paint(r: Renderer?, f: Art.Fonts, g: Game): { Hit }
    SWAP = g.ctx ~= nil and g.ctx.swap == true
    CHILLER = if g.ctx ~= nil and g.ctx.chiller ~= nil then g.ctx.chiller else 1
    local hits: { Hit } = {}
    rr(r, 0, 0, Games.W, Games.H, 18, BG)
    rr(r, 24, 22, 92, 22, 11, Color.rgba(246, 176, 46, 46))
    txt(r, if Games.round >= 2 then "ROUND 2" else "MINI GAME", f.bold, 11, AMBER, 24, 27, 92, "center")
    txt(r, g.title, f.bold, 24, FG, 130, 20, 400)
    -- The clock and what gold takes.
    -- The countdown: time left, and a bar under the header that turns red in the last 10 s.
    local left = math.max(0, g.limit - (if g.solved then g.solvedAt else g.t))
    local urgent = left <= 10 and not g.solved
    local blink = urgent and math.floor(g.t * 4) % 2 == 0
    txt(r, clock(math.ceil(left)), f.mono, 17, if urgent then (if blink then RED else Color.rgb(255, 150, 140)) else FG, 520, 16, 110, "right")
    txt(r, "TIME LEFT  ·  " .. goldTarget(g), f.bold, 10.5, if urgent then RED else AMBER, 400, 40, 230, "right")
    rr(r, 0, 4, Games.W, 5, 2, Color.rgba(255, 255, 255, 18))
    rr(r, 0, 4, Games.W * left / g.limit, 5, 2, if urgent then RED elseif left / g.limit < 0.4 then AMBER else GREEN)
    button(r, hits, f, Games.W - 176, 18, 152, 32, "Back to the room", "close", "quiet")
    local iy = 60
    for _, l in wrap(f.body, g.intro, 14, Games.W - 48) do
        txt(r, l, f.body, 14, MUTED, 24, iy, Games.W - 48)
        iy += 19
    end
    if g.kind == "lockout" then paintLockout(r, f, g, hits)
    elseif g.kind == "lineup" then paintLineup(r, f, g, hits)
    elseif g.kind == "tower" then paintTower(r, f, g, hits)
    elseif g.kind == "balance" then paintBalance(r, f, g, hits)
    elseif g.kind == "inspect" then paintInspect(r, f, g, hits)
    elseif g.kind == "drive" then paintDrive(r, f, g, hits)
    elseif g.kind == "match" then paintMatch(r, f, g, hits)
    elseif g.kind == "isolate" then paintIsolate(r, f, g, hits)
    elseif g.kind == "spot" then paintSpot(r, f, g, hits)
    elseif g.kind == "evidence" then paintEvidence(r, f, g, hits)
    elseif g.kind == "contain" then paintContain(r, f, g, hits) end
    -- Footer: feedback on the left, the check button on the right.
    local msg = g.message
    if msg ~= nil and not g.solved then
        local ly = Games.H - 56
        for _, l in wrap(f.bold, msg, 13.5, 560) do
            txt(r, l, f.bold, 13.5, if g.messageGood then GREEN else RED, 24, ly, 560)
            ly += 18
        end
    end
    if g.kind == "evidence" and not g.solved then
        button(r, hits, f, Games.W - 204, Games.H - 58, 180, 40, "Solve the case", "solve", "primary")
    end
    if g.kind == "lineup" and not g.solved then
        button(r, hits, f, Games.W - 204, Games.H - 58, 180, 40, "Check line-up", "check", "primary")
    end
    if g.timedOut then
        local outHits: { Hit } = {}
        rr(r, 0, 0, Games.W, Games.H, 18, Color.rgba(10, 14, 18, 210))
        local w, h = 440, 250
        local x, y = (Games.W - w) / 2, (Games.H - h) / 2
        rr(r, x, y, w, h, 18, Color.rgb(28, 34, 42))
        txt(r, "TIME'S UP!", f.bold, 30, RED, x, y + 26, w, "center")
        local ly = y + 76
        for _, l in wrap(f.body, "The clock beat you this time. Try again for full points, or skip it and keep going.", 15, w - 60) do
            txt(r, l, f.body, 15, FG, x + 30, ly, w - 60, "center")
            ly += 20
        end
        button(r, outHits, f, x + 30, y + h - 64, 180, 42, "Try again", "retry", "primary")
        button(r, outHits, f, x + w - 210, y + h - 64, 180, 42, "Skip (0 points)", "skip", "quiet")
        return outHits
    end
    if g.solved then
        local solvedHits: { Hit } = {}
        paintSolved(r, f, g, solvedHits)
        return solvedHits -- only Continue is live once solved
    end
    return hits
end

return Games
