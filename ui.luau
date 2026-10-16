-- The training interface, drawn by the Rive renderer over the 3D view: the inspect
-- panel, the pipe-highlight toolbar and the hover hint. Each paints into its own
-- small canvas only when its content changes; main.luau composites them.
-- Coordinates here are in layout points; the canvases are at device scale.

local Art = require("art")
local Training = require("training")

local UI = {}

export type Button = { x: number, y: number, w: number, h: number, action: string }
export type Reading = { label: string, value: string }
-- Training scenario content (sim.luau builds these).
export type Line = { text: string, tone: string?, kind: string? }
export type SimButton = { label: string, action: string, style: string? }
export type Extra = { heading: string, lines: { Line }, buttons: { SimButton } }
export type Card = { title: string, sub: string, lines: { Line }, buttons: { SimButton } }

export type PanelState = {
    id: string,
    open: boolean?, -- valves: current state
    moving: boolean?, -- valves: handwheel still turning
    readings: { Reading },
    conceal: string?, -- scenario: a generic name while the trainee must identify it
    extra: Extra?, -- scenario: objective section and its buttons
    knowledge: boolean?, -- Equipment Knowledge Mode: issues and checks
}

UI.PANEL_W = 380
UI.PANEL_MAX_H = 700
UI.TOOLBAR_W = 760
UI.TOOLBAR_H = 46
UI.CARD_W = 380
UI.CARD_MAX_H = 900
UI.BANNER_W = 560
UI.BANNER_H = 52

local BG = Color.rgba(14, 18, 24, 236)
local LINE = Color.rgba(255, 255, 255, 30)
local FG = Color.rgb(232, 237, 242)
local MUTED = Color.rgb(150, 162, 176)
local ACCENT = Color.rgb(64, 200, 236)
local AMBER = Color.rgb(246, 176, 46)
local GREEN = Color.rgb(84, 214, 120)
local RED = Color.rgb(232, 96, 82)

UI.CIRCUITS = {
    { code = "CHWS", label = "CHW supply", color = Color.rgb(48, 120, 255) },
    { code = "CHWR", label = "CHW return", color = Color.rgb(26, 210, 226) },
    { code = "CWS", label = "CW supply", color = Color.rgb(60, 220, 90) },
    { code = "CWR", label = "CW return", color = Color.rgb(255, 140, 32) },
}

local function roundRect(r: Renderer, x: number, y: number, w: number, h: number, rad: number, color: Color)
    local k = rad * 0.5523
    local p = Path.new()
    p:moveTo(Vector.xy(x + rad, y))
    p:lineTo(Vector.xy(x + w - rad, y)); p:cubicTo(Vector.xy(x + w - rad + k, y), Vector.xy(x + w, y + rad - k), Vector.xy(x + w, y + rad))
    p:lineTo(Vector.xy(x + w, y + h - rad)); p:cubicTo(Vector.xy(x + w, y + h - rad + k), Vector.xy(x + w - rad + k, y + h), Vector.xy(x + w - rad, y + h))
    p:lineTo(Vector.xy(x + rad, y + h)); p:cubicTo(Vector.xy(x + rad - k, y + h), Vector.xy(x, y + h - rad + k), Vector.xy(x, y + h - rad))
    p:lineTo(Vector.xy(x, y + rad)); p:cubicTo(Vector.xy(x, y + rad - k), Vector.xy(x + rad - k, y), Vector.xy(x + rad, y))
    p:close()
    r:drawPath(p, Paint.with({ color = color }))
end
UI.roundRect = roundRect

-- Greedy word wrap into lines no wider than w.
local function wrap(font: Art.FontRef, s: string, size: number, w: number): { string }
    local lines: { string } = {}
    local line = ""
    for word in string.gmatch(s, "%S+") do
        local test = if line == "" then word else line .. " " .. word
        if line ~= "" and Art.measure(font, test, size) > w then
            table.insert(lines, line)
            line = word
        else
            line = test
        end
    end
    if line ~= "" then table.insert(lines, line) end
    return lines
end

local function toneColor(tone: string?, default: Color): Color
    if tone == "good" then return GREEN
    elseif tone == "bad" then return RED
    elseif tone == "warn" then return AMBER
    elseif tone == "muted" then return MUTED
    elseif tone == "accent" then return ACCENT end
    return default
end

-- A status mark: a filled check (good), a cross (bad) or an open ring (to do).
local function mark(r: Renderer, cx: number, cy: number, tone: string?)
    if tone == "good" or tone == "bad" then
        Art.disc(r, cx, cy, 6.5, if tone == "good" then GREEN else RED)
        local p = Path.new()
        if tone == "good" then
            p:moveTo(Vector.xy(cx - 3.2, cy + 0.2)); p:lineTo(Vector.xy(cx - 0.8, cy + 2.6)); p:lineTo(Vector.xy(cx + 3.4, cy - 2.6))
        else
            p:moveTo(Vector.xy(cx - 2.6, cy - 2.6)); p:lineTo(Vector.xy(cx + 2.6, cy + 2.6))
            p:moveTo(Vector.xy(cx + 2.6, cy - 2.6)); p:lineTo(Vector.xy(cx - 2.6, cy + 2.6))
        end
        r:drawPath(p, Paint.with({ style = "stroke", thickness = 1.8, color = Color.rgb(14, 18, 24), cap = "round", join = "round" }))
    else
        local k = 6 * 0.5523
        local p = Path.new()
        p:moveTo(Vector.xy(cx + 6, cy))
        p:cubicTo(Vector.xy(cx + 6, cy + k), Vector.xy(cx + k, cy + 6), Vector.xy(cx, cy + 6))
        p:cubicTo(Vector.xy(cx - k, cy + 6), Vector.xy(cx - 6, cy + k), Vector.xy(cx - 6, cy))
        p:cubicTo(Vector.xy(cx - 6, cy - k), Vector.xy(cx - k, cy - 6), Vector.xy(cx, cy - 6))
        p:cubicTo(Vector.xy(cx + k, cy - 6), Vector.xy(cx + 6, cy - k), Vector.xy(cx + 6, cy))
        p:close()
        r:drawPath(p, Paint.with({ style = "stroke", thickness = 1.4, color = MUTED }))
    end
end

-- A five-point star centred on cx, cy.
local function star(r: Renderer, cx: number, cy: number, rad: number, color: Color)
    local p = Path.new()
    for i = 0, 9 do
        local a = -math.pi / 2 + i * math.pi / 5
        local rr = if i % 2 == 0 then rad else rad * 0.45
        local v = Vector.xy(cx + math.cos(a) * rr, cy + math.sin(a) * rr)
        if i == 0 then p:moveTo(v) else p:lineTo(v) end
    end
    p:close()
    r:drawPath(p, Paint.with({ color = color }))
end
UI.star = star

-- Lays out scenario lines and buttons from y; drawing is queued in ops. Returns the new y.
local function layoutBlock(fonts: Art.Fonts, lines: { Line }, buttons: { SimButton }, x: number, w: number, y: number,
    add: (() -> ()) -> (), getR: () -> Renderer, out: { Button }): number
    for _, ln in lines do
        local kind = ln.kind
        if kind == "head" then
            local ly = y + 4
            add(function() Art.text(getR(), ln.text, fonts.bold, 11, MUTED, x, ly, w) end)
            y += 22
        elseif kind == "rule" then
            local ly = y + 4
            add(function() Art.rect(getR(), x, ly, w, 1, LINE) end)
            y += 12
        elseif kind == "progress" then
            -- "step|total|points": a segmented bar and the running score.
            local parts: { string } = {}
            for part in string.gmatch(ln.text, "[^|]+") do table.insert(parts, part) end
            local cur, total, pts = tonumber(parts[1]) or 0, tonumber(parts[2]) or 1, parts[3] or "0"
            local ly = y
            add(function()
                local rr = getR()
                local label = pts .. (if pts == "1" then " pt" else " pts")
                local lw = Art.measure(fonts.bold, label, 13) + 26
                local barW = w - lw - 12
                local gap = 4
                local seg = (barW - gap * (total - 1)) / total
                for i = 1, total do
                    local col = if i < cur then GREEN elseif i == cur then ACCENT else Color.rgba(255, 255, 255, 34)
                    roundRect(rr, x + (i - 1) * (seg + gap), ly + 6, seg, 6, 3, col)
                end
                roundRect(rr, x + w - lw, ly, lw, 20, 10, Color.rgba(246, 176, 46, 46))
                star(rr, x + w - lw + 11, ly + 10, 6, AMBER)
                Art.text(rr, label, fonts.bold, 13, AMBER, x + w - lw + 20, ly + 3, lw - 22)
            end)
            y += 30
        elseif kind == "cheer" then
            -- A banner line before a quiz: green pill, bold caps, a star at each end.
            local ly = y
            local cl = wrap(fonts.bold, ln.text, 15, w - 56)
            local bh = 14 + #cl * 19
            add(function()
                local rr = getR()
                roundRect(rr, x, ly, w, bh, 10, Color.rgba(70, 235, 100, 40))
                star(rr, x + 16, ly + bh / 2, 7, GREEN)
                star(rr, x + w - 16, ly + bh / 2, 7, GREEN)
                for i, l in cl do Art.text(rr, l, fonts.bold, 15, GREEN, x + 28, ly + 8 + (i - 1) * 19, w - 56, "center") end
            end)
            y += bh + 10
        elseif kind == "objective" then
            for _, l in wrap(fonts.bold, ln.text, 18, w) do
                local ly = y
                add(function() Art.text(getR(), l, fonts.bold, 18, toneColor(ln.tone, FG), x, ly, w) end)
                y += 23
            end
            y += 4
        elseif kind == "stars" then
            local n = tonumber(ln.text) or 0
            local ly = y
            add(function()
                local rr = getR()
                for i = 1, 3 do
                    local cx = x + w / 2 + (i - 2) * 52
                    star(rr, cx, ly + 24, if i == 2 then 24 else 20, if i <= n then AMBER else Color.rgba(255, 255, 255, 34))
                end
            end)
            y += 54
        elseif kind == "big" then
            local ly = y
            add(function() Art.text(getR(), ln.text, fonts.bold, 40, toneColor(ln.tone, FG), x, ly, w) end)
            y += 48
        elseif kind == "score" then
            local bar = string.find(ln.text, "|", 1, true) or (#ln.text + 1)
            local label, value = string.sub(ln.text, 1, bar - 1), string.sub(ln.text, bar + 1)
            local ly = y
            add(function()
                Art.text(getR(), label, fonts.body, 13, MUTED, x, ly, w * 0.7)
                Art.text(getR(), value, fonts.mono, 13, FG, x + w * 0.6, ly, w * 0.4, "right")
            end)
            y += 19
        elseif kind == "check" then
            local first = true
            for _, l in wrap(fonts.body, ln.text, 13, w - 22) do
                local ly, isFirst = y, first
                add(function()
                    if isFirst then mark(getR(), x + 6, ly + 8, ln.tone) end
                    Art.text(getR(), l, fonts.body, 13, if ln.tone == nil then FG else toneColor(ln.tone, FG), x + 20, ly, w - 22)
                end)
                y += 17
                first = false
            end
            y += 3
        else
            for _, l in wrap(fonts.body, ln.text, 13.5, w) do
                local ly = y
                add(function() Art.text(getR(), l, fonts.body, 13.5, toneColor(ln.tone, FG), x, ly, w) end)
                y += 18
            end
            y += 4
        end
    end
    for _, b in buttons do
        y += 4
        local style = b.style or "choice"
        local head, rest = b.label, nil :: string?
        local dash = string.find(b.label, " — ", 1, true)
        if dash ~= nil then head, rest = string.sub(b.label, 1, dash - 1), string.sub(b.label, dash + 5) end
        if style == "abc" then
            -- "A|text": a lettered answer.
            local bar = string.find(b.label, "|", 1, true) or 0
            local letter, text = string.sub(b.label, 1, bar - 1), string.sub(b.label, bar + 1)
            local tl = wrap(fonts.body, text, 13.5, w - 52)
            local h = math.max(38, #tl * 18 + 18)
            local by = y
            table.insert(out, { x = x, y = by, w = w, h = h, action = b.action })
            add(function()
                local rr = getR()
                roundRect(rr, x, by, w, h, 8, Color.rgba(255, 255, 255, 20))
                Art.disc(rr, x + 19, by + h / 2, 11, Color.rgba(64, 200, 236, 60))
                Art.text(rr, letter, fonts.bold, 13, ACCENT, x + 8, by + h / 2 - 8, 22, "center")
                local ty = by + (h - #tl * 18) / 2 + 1
                for _, l in tl do
                    Art.text(rr, l, fonts.body, 13.5, FG, x + 40, ty, w - 52)
                    ty += 18
                end
            end)
            y += h
            continue
        end
        local hl = wrap(fonts.bold, head, 13.5, w - 24)
        local rl = if rest ~= nil then wrap(fonts.body, rest, 12.5, w - 24) else {}
        if style == "choice" and rest == nil then hl = wrap(fonts.body, head, 13.5, w - 24) end
        local h = math.max(if style == "go" then 44 else 34, #hl * 18 + #rl * 16 + 16)
        local by = y
        table.insert(out, { x = x, y = by, w = w, h = h, action = b.action })
        add(function()
            local rr = getR()
            if style == "hint" then
                roundRect(rr, x, by, w, h, 6, Color.rgba(246, 176, 46, 70))
                roundRect(rr, x + 1, by + 1, w - 2, h - 2, 5, Color.rgba(14, 18, 24, 236))
            elseif style == "primary" then
                roundRect(rr, x, by, w, h, 6, Color.rgba(64, 200, 236, 52))
            elseif style == "go" then
                roundRect(rr, x, by, w, h, h / 2, GREEN)
            elseif style == "choice" then
                roundRect(rr, x, by, w, h, 6, Color.rgba(255, 255, 255, 20))
            end
            local ty = by + 8 + (if #hl + #rl == 1 then (h - 34) / 2 + 1 else 0)
            local color = if style == "go" then Color.rgb(10, 14, 18) elseif style == "primary" then ACCENT elseif style == "quiet" then MUTED elseif style == "hint" then AMBER else FG
            local align: any = if style == "choice" then nil else "center"
            local font = if style == "choice" and rest == nil then fonts.body else fonts.bold
            for _, l in hl do
                Art.text(rr, l, font, 13.5, color, x + 12, ty, w - 24, align)
                ty += 18
            end
            for _, l in rl do
                Art.text(rr, l, fonts.body, 12.5, MUTED, x + 12, ty, w - 24, align)
                ty += 16
            end
        end)
        y += h
    end
    return y
end

-- Paints the inspect panel for one id; returns its height and its buttons (panel-local).
-- With no renderer it only lays out, so clicks can be hit-tested before the first paint.
function UI.paintPanel(r: Renderer?, fonts: Art.Fonts, st: PanelState): (number, { Button })
    local info = Training[st.id]
    local buttons: { Button } = {}
    local rr = r
    r = (rr :: any)
    local W, pad = UI.PANEL_W, 18
    local inner = W - pad * 2
    -- Lay out first, then draw the background to fit.
    local ops: { () -> () } = {}
    local y = pad
    local function add(f: () -> ()) table.insert(ops, f) end
    local kind = if info ~= nil then info.kind else "EQUIPMENT"
    local title = if st.conceal ~= nil then st.conceal elseif info ~= nil then info.title else st.id
    local scenario = st.extra ~= nil or st.conceal ~= nil
    local ky = y
    add(function() Art.text(r, kind, fonts.bold, 11, ACCENT, pad, ky, inner - 30) end)
    y += 18
    for _, l in wrap(fonts.bold, title, 19, inner - 30) do
        local ly = y
        add(function() Art.text(r, l, fonts.bold, 19, FG, pad, ly, inner - 30) end)
        y += 24
    end
    y += 4
    local by = y
    add(function()
        roundRect(r, pad, by, 178, 20, 4, Color.rgba(246, 176, 46, 40))
        Art.text(r, "SIMULATED TRAINING DATA", fonts.bold, 10.5, AMBER, pad + 8, by + 4, 170)
    end)
    y += 30
    local extra = st.extra
    if extra ~= nil then
        -- The scenario's section comes first, so its buttons are always in view.
        local ex: Extra = extra
        local top = y
        local h0 = 0
        local exOps: { () -> () } = {}
        local function exAdd(f: () -> ()) table.insert(exOps, f) end
        local yEnd = layoutBlock(fonts, { { kind = "head", text = ex.heading } }, {}, pad + 12, inner - 24, y + 6, exAdd, function() return r end, buttons)
        yEnd = layoutBlock(fonts, ex.lines, ex.buttons, pad + 12, inner - 24, yEnd, exAdd, function() return r end, buttons)
        h0 = yEnd - top + 10
        add(function()
            roundRect(r, pad, top, inner, h0, 8, Color.rgba(64, 200, 236, 22))
            Art.rect(r, pad, top, 3, h0, ACCENT)
            for _, f in exOps do f() end
        end)
        y = top + h0 + 12
    end
    if info ~= nil and st.conceal ~= nil then
        for _, l in wrap(fonts.body, "Identify it from the pipe markers, labels and tags around it.", 14, inner) do
            local ly = y
            add(function() Art.text(r, l, fonts.body, 14, MUTED, pad, ly, inner) end)
            y += 19
        end
    elseif info ~= nil then
        for _, l in wrap(fonts.body, info.purpose, 14, inner) do
            local ly = y
            add(function() Art.text(r, l, fonts.body, 14, FG, pad, ly, inner) end)
            y += 19
        end
        y += 6
        for _, point in (if scenario or st.knowledge then {} else info.points) do
            local first = true
            for _, l in wrap(fonts.body, point, 13, inner - 14) do
                local ly, isFirst = y, first
                add(function()
                    if isFirst then Art.disc(r, pad + 3, ly + 8, 2.2, MUTED) end
                    Art.text(r, l, fonts.body, 13, MUTED, pad + 14, ly, inner - 14)
                end)
                y += 17
                first = false
            end
            y += 3
        end
    end
    if #st.readings > 0 then
        y += 8
        local ly = y
        add(function()
            Art.rect(r, pad, ly, inner, 1, LINE)
            Art.text(r, "READINGS (SIMULATED)", fonts.bold, 11, MUTED, pad, ly + 8, inner)
        end)
        y += 28
        for _, rd in st.readings do
            local ry = y
            add(function()
                Art.text(r, rd.label, fonts.body, 13, MUTED, pad, ry, inner * 0.5)
                local v = rd.value
                local function starts(p: string): boolean return string.sub(v, 1, #p) == p end
                local col = if starts("RUNNING") or v == "OPEN" then GREEN
                    elseif starts("STOPPED") or starts("STANDBY") or starts("WARNING") then AMBER
                    elseif v == "CLOSED" or starts("FAULT") or starts("F0") then RED else FG
                Art.text(r, rd.value, fonts.mono, 13, col, pad + inner * 0.45, ry, inner * 0.55, "right")
            end)
            y += 19
        end
    end
    if info ~= nil and st.knowledge then
        local function section(head: string, items: { string }?)
            if items == nil or #items == 0 then return end
            y += 8
            local hy = y
            add(function()
                Art.rect(r, pad, hy, inner, 1, LINE)
                Art.text(r, head, fonts.bold, 11, MUTED, pad, hy + 8, inner)
            end)
            y += 28
            for _, point in items do
                local first = true
                for _, l in wrap(fonts.body, point, 13, inner - 14) do
                    local ly, isFirst = y, first
                    add(function()
                        if isFirst then Art.disc(r, pad + 3, ly + 8, 2.2, MUTED) end
                        Art.text(r, l, fonts.body, 13, FG, pad + 14, ly, inner - 14)
                    end)
                    y += 17
                    first = false
                end
                y += 3
            end
        end
        section("COMMON ISSUES", info.issues)
        section("WHAT TECHNICIANS INSPECT", info.checks)
    end
    if info ~= nil and info.valve then
        y += 10
        local vy = y
        local isOpen = st.open ~= false
        local label = if st.moving then "Valve moving..." elseif isOpen then "Close valve" else "Open valve"
        table.insert(buttons, { x = pad, y = vy, w = inner, h = 36, action = "toggle" })
        add(function()
            roundRect(r, pad, vy, inner, 36, 6, if st.moving then Color.rgba(255, 255, 255, 24) else Color.rgba(64, 200, 236, 52))
            Art.text(r, label, fonts.bold, 14, if st.moving then MUTED else ACCENT, pad, vy + 10, inner, "center")
        end)
        y += 44
        if info.training then
            local ny = y
            add(function() Art.text(r, if scenario or st.knowledge then "Training valve: simulated, the plant is not affected." else "Training valve: watch the handwheel turn.", fonts.body, 12, MUTED, pad, ny, inner) end)
            y += 18
        end
    end
    if info ~= nil and info.safety ~= nil and st.conceal == nil then
        y += 8
        local lines = wrap(fonts.body, info.safety, 12.5, inner - 20)
        local sy, sh = y, #lines * 17 + 14
        add(function()
            roundRect(r, pad, sy, inner, sh, 6, Color.rgba(232, 96, 82, 34))
            Art.rect(r, pad, sy, 3, sh, RED)
        end)
        for i, l in lines do
            local ly = sy + 8 + (i - 1) * 17
            add(function() Art.text(r, l, fonts.body, 12.5, FG, pad + 12, ly, inner - 20) end)
        end
        y += sh
    end
    y += pad
    local H = math.min(y, UI.PANEL_MAX_H)
    table.insert(buttons, { x = W - 44, y = 8, w = 36, h = 36, action = "close" })
    if r ~= nil then
        roundRect(r, 0, 0, W, H, 12, BG)
        Art.text(r, "×", fonts.body, 24, MUTED, W - 44, 10, 36, "center")
        for _, f in ops do f() end
    end
    return H, buttons
end

-- Paints the scenario card; returns its height and buttons (card-local).
-- With no renderer it only lays out.
function UI.paintCard(r: Renderer?, fonts: Art.Fonts, card: Card): (number, { Button })
    local buttons: { Button } = {}
    local W, pad = UI.CARD_W, 18
    local inner = W - pad * 2
    local ops: { () -> () } = {}
    local function add(f: () -> ()) table.insert(ops, f) end
    local function getR(): Renderer return (r :: any) end
    local y = pad
    add(function()
        roundRect(getR(), pad, pad, math.min(Art.measure(fonts.bold, card.sub, 10.5) + 16, inner), 20, 4, Color.rgba(246, 176, 46, 40))
        Art.text(getR(), card.sub, fonts.bold, 10.5, AMBER, pad + 8, pad + 4, inner - 16)
    end)
    y += 28
    for _, l in wrap(fonts.bold, card.title, 19, inner) do
        local ly = y
        add(function() Art.text(getR(), l, fonts.bold, 19, FG, pad, ly, inner) end)
        y += 24
    end
    y += 6
    y = layoutBlock(fonts, card.lines, card.buttons, pad, inner, y, add, getR, buttons)
    y += pad
    local H = math.min(y, UI.CARD_MAX_H)
    if r ~= nil then
        roundRect(r, 0, 0, W, H, 12, BG)
        for _, f in ops do f() end
    end
    return H, buttons
end

-- Paints the alarm banner; returns its width.
function UI.paintBanner(r: Renderer, fonts: Art.Fonts, s: string, acked: boolean): number
    local w = math.min(Art.measure(fonts.bold, s, 15) + 84, UI.BANNER_W)
    roundRect(r, 0, 0, w, UI.BANNER_H, 10, if acked then Color.rgba(60, 40, 16, 236) else Color.rgba(150, 30, 24, 240))
    Art.disc(r, 26, UI.BANNER_H / 2, 7, if acked then AMBER else Color.rgb(255, 220, 210))
    Art.text(r, if acked then "ALARM SILENCED · SIMULATED" else "ALARM · SIMULATED", fonts.bold, 10.5, if acked then AMBER else Color.rgb(255, 200, 190), 44, 9, w - 56)
    Art.text(r, s, fonts.bold, 15, FG, 44, 25, w - 56)
    return w
end

-- The toolbar's buttons (toolbar-local); fixed, so clicks work before it has painted.
function UI.toolbarButtons(): { Button }
    local buttons: { Button } = {}
    local x = 70
    for i = 1, #UI.CIRCUITS do
        table.insert(buttons, { x = x, y = 7, w = 108, h = 32, action = "hl" .. i })
        x += 114
    end
    table.insert(buttons, { x = x, y = 7, w = 60, h = 32, action = "hl0" })
    table.insert(buttons, { x = x + 74, y = 7, w = 150, h = 32, action = "sim" })
    return buttons
end

-- Paints the pipe-highlight toolbar; returns its buttons (toolbar-local).
function UI.paintToolbar(r: Renderer, fonts: Art.Fonts, highlight: number, simOn: boolean): { Button }
    local buttons: { Button } = {}
    roundRect(r, 0, 0, UI.TOOLBAR_W, UI.TOOLBAR_H, 10, BG)
    Art.text(r, "PIPING", fonts.bold, 11, MUTED, 14, 17, 60)
    local x = 70
    for i, c in UI.CIRCUITS do
        local on = highlight == i
        local w = 108
        roundRect(r, x, 7, w, 32, 6, if on then c.color else Color.rgba(255, 255, 255, 18))
        Art.disc(r, x + 14, 23, 5, if on then Color.rgb(255, 255, 255) else c.color)
        Art.text(r, c.label, fonts.bold, 12.5, if on then Color.rgb(10, 14, 18) else FG, x + 24, 15, w - 28)
        table.insert(buttons, { x = x, y = 7, w = w, h = 32, action = "hl" .. i })
        x += w + 6
    end
    roundRect(r, x, 7, 60, 32, 6, Color.rgba(255, 255, 255, if highlight == 0 then 40 else 18))
    Art.text(r, "Off", fonts.bold, 12.5, FG, x, 15, 60, "center")
    table.insert(buttons, { x = x, y = 7, w = 60, h = 32, action = "hl0" })
    Art.rect(r, x + 67, 11, 1, 24, LINE)
    roundRect(r, x + 74, 7, 150, 32, 6, if simOn then Color.rgba(246, 176, 46, 60) else Color.rgba(64, 200, 236, 52))
    Art.text(r, if simOn then "End Simulation" else "Begin Simulation", fonts.bold, 12.5, if simOn then AMBER else ACCENT, x + 74, 15, 150, "center")
    table.insert(buttons, { x = x + 74, y = 7, w = 150, h = 32, action = "sim" })
    return buttons
end

UI.TOAST_W = 420
UI.TOAST_H = 56
UI.TAG_W = 220
UI.TAG_H = 26

-- Paints a toast ("+2  Found it!"); returns its width.
function UI.paintToast(r: Renderer, fonts: Art.Fonts, text: string, tone: string, points: number): number
    local col = if tone == "good" then GREEN elseif tone == "warn" then AMBER else RED
    local tint = if tone == "good" then Color.rgba(84, 214, 120, 40) elseif tone == "warn" then Color.rgba(246, 176, 46, 40) else Color.rgba(232, 96, 82, 40)
    local badge = if points > 0 then "+" .. points else ""
    local bw = if badge ~= "" then Art.measure(fonts.bold, badge, 22) + 26 else 0
    local w = math.min(Art.measure(fonts.bold, text, 17) + bw + 40, UI.TOAST_W)
    roundRect(r, 0, 0, w, UI.TOAST_H, UI.TOAST_H / 2, BG)
    roundRect(r, 2, 2, w - 4, UI.TOAST_H - 4, UI.TOAST_H / 2 - 2, tint)
    local x = 20
    if badge ~= "" then
        roundRect(r, 10, 10, bw, UI.TOAST_H - 20, (UI.TOAST_H - 20) / 2, col)
        Art.text(r, badge, fonts.bold, 22, Color.rgb(10, 14, 18), 10, 15, bw, "center")
        x = bw + 22
    end
    Art.text(r, text, fonts.bold, 17, FG, x, 18, w - x - 18)
    return w
end

-- Paints a marker's tag ("CHWP-1 · 6 m"); returns its width.
function UI.paintTag(r: Renderer, fonts: Art.Fonts, text: string, zone: boolean, red: boolean?): number
    local w = math.min(Art.measure(fonts.bold, text, 13) + 24, UI.TAG_W)
    local bg = if red then Color.rgba(235, 50, 40, 240) elseif zone then Color.rgba(246, 176, 46, 235) else Color.rgba(70, 235, 100, 235)
    roundRect(r, 0, 0, w, UI.TAG_H, UI.TAG_H / 2, bg)
    Art.text(r, text, fonts.bold, 13, if red then Color.rgb(255, 255, 255) else Color.rgb(10, 14, 18), 12, 6, w - 24)
    return w
end

-- Paints the hover hint ("CHWP-1 ... · click to inspect"); returns its width.
function UI.paintHint(r: Renderer, fonts: Art.Fonts, id: string, conceal: string?): number
    local info = Training[id]
    local s = (if conceal ~= nil then conceal elseif info ~= nil then info.title else id) .. "   ·   click to inspect"
    local w = math.min(Art.measure(fonts.bold, s, 13) + 28, 560)
    roundRect(r, 0, 0, w, 30, 15, BG)
    Art.text(r, s, fonts.bold, 13, FG, 14, 8, w - 28)
    return w
end

return UI
