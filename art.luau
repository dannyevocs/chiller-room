-- 2D art painted into canvases that room.wgsl samples on 3D quads: a static
-- label atlas (pipe markers, tags, signs) and a live screen atlas (the chiller
-- HMI, pump drive displays, the refrigerant monitor and gauge dials), plus the
-- simulated plant telemetry that drives the live art.
--
-- Atlas frames come from scene_meta.luau (exported from Blender). Each gets a
-- cell sized to its real-world aspect; layout() returns the cells, and the
-- shader maps world points on a quad into its cell.

local Glyphs = require("glyphs")

local Art = {}

-- A font is a runtime Font, or the name of a baked outline set in glyphs.luau
-- for runtimes without a font API (the 2.43 web runtime).
export type FontRef = any
export type Fonts = { body: FontRef, bold: FontRef, mono: FontRef }
export type Cell = { name: string, tex: number, x: number, y: number, w: number, h: number }

-- Atlas textures: 1 static labels; 2 the chiller HMI; 3 the small screens and gauges.
-- The two live ones are painted on alternate ticks so no frame paints both.
Art.SIZES = { { 2048, 2048 }, { 1024, 1024 }, { 1024, 1024 } }

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

local function texFor(name: string): number
    if string.find(name, "Control Panel Screen", 1, true) ~= nil then return 2 end
    if string.find(name, "Screen", 1, true) ~= nil or string.find(name, "Gauge", 1, true) ~= nil then return 3 end
    return 1
end

type Item = { i: number, name: string, w: number, h: number }

local function len3(t: { number }): number
    return math.sqrt(t[1] * t[1] + t[2] * t[2] + t[3] * t[3])
end

-- Shelf-packs every frame into its atlas at a pixels-per-metre density that fits.
function Art.layout(frames: { any }): { Cell }
    local cells: { Cell } = {}
    for tex, size in Art.SIZES do
        local W, H = size[1], size[2]
        local items: { Item } = {}
        for i, f in frames do
            if texFor(f.name) == tex then
                table.insert(items, { i = i, name = f.name, w = len3(f.u), h = len3(f.v) })
            end
        end
        table.sort(items, function(a: Item, b: Item): boolean return a.h > b.h end)
        local density = if tex == 1 then 1400 else 1500
        while density > 100 do
            local x, y, shelf, ok = 0, 0, 0, true
            local placed = {}
            for _, it in items do
                local w, h = math.ceil(it.w * density) + 4, math.ceil(it.h * density) + 4
                if x + w > W then x, y, shelf = 0, y + shelf, 0 end
                if y + h > H or w > W then ok = false; break end
                placed[it.i] = { name = it.name, tex = tex, x = x + 2, y = y + 2, w = w - 4, h = h - 4 }
                x += w; shelf = math.max(shelf, h)
            end
            if ok then
                for i, c in placed do cells[i] = c end
                break
            end
            density *= 0.9
        end
    end
    return cells
end

-- ---------------------------------------------------------------------------
-- Drawing helpers
-- ---------------------------------------------------------------------------

local function rect(r: Renderer, x: number, y: number, w: number, h: number, color: Color)
    local p = Path.new()
    p:moveTo(Vector.xy(x, y)); p:lineTo(Vector.xy(x + w, y)); p:lineTo(Vector.xy(x + w, y + h)); p:lineTo(Vector.xy(x, y + h)); p:close()
    r:drawPath(p, Paint.with({ color = color }))
end

local function frameRect(r: Renderer, x: number, y: number, w: number, h: number, t: number, color: Color)
    rect(r, x, y, w, t, color); rect(r, x, y + h - t, w, t, color)
    rect(r, x, y, t, h, color); rect(r, x + w - t, y, t, h, color)
end

local K = 0.5523
local function circlePath(cx: number, cy: number, rad: number): Path
    local p = Path.new()
    local k = rad * K
    p:moveTo(Vector.xy(cx + rad, cy))
    p:cubicTo(Vector.xy(cx + rad, cy + k), Vector.xy(cx + k, cy + rad), Vector.xy(cx, cy + rad))
    p:cubicTo(Vector.xy(cx - k, cy + rad), Vector.xy(cx - rad, cy + k), Vector.xy(cx - rad, cy))
    p:cubicTo(Vector.xy(cx - rad, cy - k), Vector.xy(cx - k, cy - rad), Vector.xy(cx, cy - rad))
    p:cubicTo(Vector.xy(cx + k, cy - rad), Vector.xy(cx + rad, cy - k), Vector.xy(cx + rad, cy))
    p:close()
    return p
end

local function disc(r: Renderer, cx: number, cy: number, rad: number, color: Color)
    r:drawPath(circlePath(cx, cy, rad), Paint.with({ color = color }))
end

-- Text from baked outlines: one path for the whole string, aligned within w.
local function outlineText(r: Renderer, s: string, data: Glyphs.FontData, size: number, color: Color, x: number, y: number, w: number, align: TextAlign?)
    local k = size / data.upem
    local width = 0
    for _, code in utf8.codes(s) do
        local g = data.glyphs[code]
        width += (if g ~= nil then g.adv else data.upem * 0.5) * k
    end
    local ox = x
    if align == "center" then ox = x + (w - width) / 2 elseif align == "right" then ox = x + w - width end
    local baseline = y + data.ascent * k
    local p = Path.new()
    local cx, cy = 0, 0   -- current point, for raising quadratics to cubics
    for _, code in utf8.codes(s) do
        local g = data.glyphs[code]
        if g ~= nil then
            local ops, i = g.ops, 1
            while i <= #ops do
                local op = ops[i]
                if op == 1 then
                    cx, cy = ox + ops[i + 1] * k, baseline - ops[i + 2] * k
                    p:moveTo(Vector.xy(cx, cy)); i += 3
                elseif op == 2 then
                    cx, cy = ox + ops[i + 1] * k, baseline - ops[i + 2] * k
                    p:lineTo(Vector.xy(cx, cy)); i += 3
                elseif op == 3 then
                    -- An exact quadratic as a cubic: the control points sit 2/3 of the way to the quad's.
                    local qx, qy = ox + ops[i + 1] * k, baseline - ops[i + 2] * k
                    local ex, ey = ox + ops[i + 3] * k, baseline - ops[i + 4] * k
                    p:cubicTo(Vector.xy(cx + (qx - cx) * 2 / 3, cy + (qy - cy) * 2 / 3), Vector.xy(ex + (qx - ex) * 2 / 3, ey + (qy - ey) * 2 / 3), Vector.xy(ex, ey))
                    cx, cy = ex, ey; i += 5
                elseif op == 4 then
                    cx, cy = ox + ops[i + 5] * k, baseline - ops[i + 6] * k
                    p:cubicTo(Vector.xy(ox + ops[i + 1] * k, baseline - ops[i + 2] * k), Vector.xy(ox + ops[i + 3] * k, baseline - ops[i + 4] * k), Vector.xy(cx, cy)); i += 7
                else
                    p:close(); i += 1
                end
            end
            ox += g.adv * k
        else
            ox += data.upem * 0.5 * k
        end
    end
    r:drawPath(p, Paint.with({ color = color }))
end

-- Text in a box: align within width w, top at y. Size is in pixels.
local measureText: (FontRef, string, number) -> number
local function text(r: Renderer, s: string, font: FontRef, size: number, color: Color, x: number, y: number, w: number, align: TextAlign?)
    -- A line never spills out of its box: shrink it to fit.
    local mw = measureText(font, s, size)
    if mw > w and mw > 0 then
        local f = w / mw * 0.98
        y += size * (1 - f) * 0.5
        size *= f
    end
    if type(font) == "string" then
        local data = Glyphs[font]
        if data ~= nil then outlineText(r, s, data, size, color, x, y, w, align) end
        return
    end
    if font == nil or (Text :: any) == nil then return end
    local t = Text.new()
    t:append(s, { font = font, size = size, paint = Paint.with({ color = color }) })
    t.origin = "top"
    t.sizing = "autoHeight"
    t.maxWidth = w
    t.align = align or "left"
    t.wrap = "noWrap"
    r:save()
    r:transform(Mat2D.withTranslation(x, y))
    t:draw(r)
    r:restore()
end

-- An arrow pointing up (dir = 1) or down (dir = -1), centred on cx, spanning y0..y1.
local function arrow(r: Renderer, cx: number, y0: number, y1: number, width: number, dir: number, color: Color)
    local tip, tail = if dir > 0 then y0 else y1, if dir > 0 then y1 else y0
    local head = width * 1.1 * dir
    local p = Path.new()
    p:moveTo(Vector.xy(cx, tip))
    p:lineTo(Vector.xy(cx + width, tip + head))
    p:lineTo(Vector.xy(cx + width * 0.38, tip + head))
    p:lineTo(Vector.xy(cx + width * 0.38, tail))
    p:lineTo(Vector.xy(cx - width * 0.38, tail))
    p:lineTo(Vector.xy(cx - width * 0.38, tip + head))
    p:lineTo(Vector.xy(cx - width, tip + head))
    p:close()
    r:drawPath(p, Paint.with({ color = color }))
end

local WHITE = Color.rgb(250, 250, 248)
local BLACK = Color.rgb(18, 20, 22)
local YELLOW = Color.rgb(246, 190, 0)
local ORANGE = Color.rgb(246, 128, 22)
local RED = Color.rgb(200, 24, 30)
local PIPE_BLUE = Color.rgb(36, 92, 170)
local PIPE_RED = Color.rgb(176, 58, 46)
local PIPE_GREEN = Color.rgb(38, 120, 66)

-- ---------------------------------------------------------------------------
-- Static labels
-- ---------------------------------------------------------------------------

local PIPES = {
    ["Label Pipe CHWS"] = { "CHILLED WATER SUPPLY", "CHWS", PIPE_BLUE, 1 },
    ["Label Pipe CHWR"] = { "CHILLED WATER RETURN", "CHWR", PIPE_RED, -1 },
    ["Label Pipe CWS"] = { "CONDENSER WATER SUPPLY", "CWS", PIPE_GREEN, -1 },
    ["Label Pipe CWR"] = { "CONDENSER WATER RETURN", "CWR", PIPE_GREEN, 1 },
    ["Label Pipe DH CHWS"] = { "TO DATA HALL 01", "CHWS", PIPE_BLUE, 1 },
}

local HPIPES: { [string]: any } = {
    ["Label HPipe CHWS L"] = { "CHILLED WATER SUPPLY  TO DATA HALL", "CHWS", PIPE_BLUE, -1 },
    ["Label HPipe CHWR R"] = { "CHILLED WATER RETURN  TO CH-1", "CHWR", Color.rgb(20, 120, 140), 1 },
    ["Label HPipe CWS R"] = { "CONDENSER WATER SUPPLY  TO CH-1", "CWS", PIPE_GREEN, 1 },
    ["Label HPipe DH CHWR"] = { "CHILLED WATER RETURN  FROM DATA HALL 01", "CHWR", Color.rgb(20, 120, 140), -1 },
}

local SIGNS: { [string]: any } = {
    ["Label Sign Emergency Shutoff"] = { "EMERGENCY", RED, { "REFRIGERATION SYSTEM", "SHUTOFF" } },
    ["Label Sign PPE"] = { "CAUTION", YELLOW, { "SAFETY GLASSES AND", "HEARING PROTECTION", "REQUIRED BEYOND THIS POINT" } },
    ["Label Sign Hearing"] = { "CAUTION", YELLOW, { "HIGH NOISE AREA", "HEARING PROTECTION", "REQUIRED" } },
    ["Label Sign Auto Start"] = { "WARNING", ORANGE, { "EQUIPMENT STARTS", "AUTOMATICALLY" } },
    ["Label Sign Arc Flash"] = { "WARNING", ORANGE, { "ARC FLASH AND", "SHOCK HAZARD", "PPE REQUIRED", "QUALIFIED", "PERSONS ONLY" } },
    ["Label Sign Rail West"] = { "NOTICE", Color.rgb(20, 80, 160), { "VALVE AREA", "AUTHORIZED", "PERSONNEL ONLY" } },
    ["Label Sign Rail South"] = { "NOTICE", Color.rgb(20, 80, 160), { "VALVE AREA", "AUTHORIZED", "PERSONNEL ONLY" } },
    ["Label Sign Fire Riser"] = { "FIRE", RED, { "SPRINKLER RISER", "CONTROL VALVE", "KEEP OPEN" } },
    ["Label Sign Rail Rear"] = { "NOTICE", Color.rgb(20, 80, 160), { "NO ACCESS", "MAINTENANCE", "WITH PERMIT ONLY" } },
    ["Label Sign HP Vents"] = { "NOTICE", Color.rgb(20, 80, 160), { "HIGH-POINT", "AIR VENTS", "CHECK WEEKLY" } },
    ["Label Sign Pump-Out"] = { "CAUTION", YELLOW, { "REFRIGERANT RECOVERY", "AND STORAGE", "CERTIFIED TECHNICIANS ONLY" } },
    ["Label Sign High Voltage TX-1"] = { "DANGER", RED, { "HIGH VOLTAGE", "KEEP OUT" } },
    ["Label Sign High Voltage TX-2"] = { "DANGER", RED, { "HIGH VOLTAGE", "KEEP OUT" } },
    ["Label Sign Yard Gate"] = { "NOTICE", Color.rgb(20, 80, 160), { "UTILITY YARD", "GENERATORS · HIGH VOLTAGE", "AUTHORIZED PERSONNEL ONLY" } },
    ["Label Sign Refrigerant Leak"] = { "DANGER", RED, { "ON A REFRIGERANT ALARM", "LEAVE THE ROOM AT ONCE", "SCBA: TRAINED RESCUE ONLY" } },
}

local function arrowRight(r: Renderer, tipX: number, cy: number, len: number, half: number, color: Color)
    local p = Path.new()
    p:moveTo(Vector.xy(tipX, cy)); p:lineTo(Vector.xy(tipX - len, cy - half)); p:lineTo(Vector.xy(tipX - len, cy + half)); p:close()
    r:drawPath(p, Paint.with({ color = color }))
end

local function arrowLeft(r: Renderer, tipX: number, cy: number, len: number, half: number, color: Color)
    local p = Path.new()
    p:moveTo(Vector.xy(tipX, cy)); p:lineTo(Vector.xy(tipX + len, cy - half)); p:lineTo(Vector.xy(tipX + len, cy + half)); p:close()
    r:drawPath(p, Paint.with({ color = color }))
end

local function paintLabel(r: Renderer, c: Cell, f: Fonts)
    local x, y, w, h = c.x, c.y, c.w, c.h
    local name = c.name
    local pipe = PIPES[name]
    if pipe ~= nil then
        -- A pipe marker reads along the pipe: background colour band, text turned 90 degrees, flow arrow.
        rect(r, x, y, w, h, pipe[3])
        rect(r, x, y, w, h * 0.04, WHITE); rect(r, x, y + h * 0.96, w, h * 0.04, WHITE)
        arrow(r, x + w * 0.5, y + h * 0.08, y + h * 0.30, w * 0.26, pipe[4], WHITE)
        r:save()
        r:transform(Mat2D.withTranslation(x + w * 0.5, y + h * 0.66) * Mat2D.withRotation(-math.pi / 2))
        text(r, pipe[2], f.bold, w * 0.42, WHITE, -h * 0.30, -w * 0.46, h * 0.60, "center")
        text(r, pipe[1], f.body, w * 0.12, WHITE, -h * 0.30, w * 0.08, h * 0.60, "center")
        r:restore()
        return
    end
    if string.sub(name, 1, 10) == "Label Pump" then
        rect(r, x, y, w, h, WHITE); frameRect(r, x, y, w, h, h * 0.06, BLACK)
        text(r, string.sub(name, 12), f.bold, h * 0.62, BLACK, x, y + h * 0.14, w, "center")
        return
    end
    if string.sub(name, 1, 15) == "Label Nameplate" then
        local n = Art.chillerNum(name)
        rect(r, x, y, w, h, Color.rgb(196, 200, 204)); frameRect(r, x, y, w, h, h * 0.03, Color.rgb(120, 124, 128))
        text(r, string.format("CH-%d   CENTRIFUGAL WATER CHILLER", n), f.bold, h * 0.13, BLACK, x + w * 0.04, y + h * 0.07, w * 0.92)
        local rows = {
            { "CAPACITY", "500 TONS (1758 kW)" }, { "REFRIGERANT", "R-1233zd(E)   CHARGE 590 kg" },
            { "ELECTRICAL", "460 V / 3 PH / 60 HZ   RLA 412 A" }, { "DESIGN PRESSURE", "EVAP 1034 kPa   COND 1034 kPa" },
            { "SERIAL", string.format("26-04%d8-CH%d   BUILT 2026", n, n) },
        }
        for i, row in rows do
            local ry = y + h * (0.27 + (i - 1) * 0.135)
            text(r, row[1], f.body, h * 0.085, Color.rgb(60, 64, 68), x + w * 0.04, ry, w * 0.3)
            text(r, row[2], f.mono, h * 0.085, BLACK, x + w * 0.34, ry, w * 0.62)
        end
        return
    end
    if string.sub(name, 1, 17) == "Label Chiller Tag" then
        rect(r, x, y, w, h, YELLOW)
        text(r, string.format("CH-%d   CHILLER CONTROL PANEL", Art.chillerNum(name)), f.bold, h * 0.6, BLACK, x, y + h * 0.16, w, "center")
        return
    end
    if name == "Label Refrigerant Warning" then
        rect(r, x, y, w, h, WHITE); frameRect(r, x, y, w, h, h * 0.02, BLACK)
        rect(r, x + h * 0.02, y + h * 0.02, w - h * 0.04, h * 0.24, ORANGE)
        local p = Path.new()   -- the warning triangle
        local tx, ty, ts = x + w * 0.1, y + h * 0.04, h * 0.2
        p:moveTo(Vector.xy(tx, ty + ts)); p:lineTo(Vector.xy(tx + ts * 0.58, ty)); p:lineTo(Vector.xy(tx + ts * 1.16, ty + ts)); p:close()
        r:drawPath(p, Paint.with({ color = BLACK }))
        text(r, "!", f.bold, ts * 0.78, ORANGE, tx, ty + ts * 0.18, ts * 1.16, "center")
        text(r, "WARNING", f.bold, h * 0.17, BLACK, x + w * 0.2, y + h * 0.045, w * 0.75, "center")
        text(r, "REFRIGERANT MACHINERY ROOM", f.bold, h * 0.09, BLACK, x, y + h * 0.33, w, "center")
        text(r, "AUTHORIZED PERSONNEL ONLY", f.body, h * 0.075, BLACK, x, y + h * 0.48, w, "center")
        text(r, "If the alarm sounds, leave the room", f.body, h * 0.065, BLACK, x, y + h * 0.64, w, "center")
        text(r, "and do not re-enter until it is ventilated.", f.body, h * 0.065, BLACK, x, y + h * 0.75, w, "center")
        return
    end
    if name == "Label Door Sign" then
        rect(r, x, y, w, h, Color.rgb(28, 64, 120))
        text(r, "MECHANICAL", f.bold, h * 0.24, WHITE, x, y + h * 0.18, w, "center")
        text(r, "ROOM M-104", f.body, h * 0.2, WHITE, x, y + h * 0.52, w, "center")
        return
    end
    if name == "Label Door Sign 2" then
        rect(r, x, y, w, h, RED)
        text(r, "AUTHORIZED", f.bold, h * 0.22, WHITE, x, y + h * 0.16, w, "center")
        text(r, "PERSONNEL ONLY", f.bold, h * 0.2, WHITE, x, y + h * 0.5, w, "center")
        return
    end
    -- Horizontal pipe markers: band colour, name, arrow in the flow direction as seen from the room.
    local hp = HPIPES[name]
    if hp ~= nil then
        rect(r, x, y, w, h, hp[3])
        local aw = h * 0.42
        if hp[4] < 0 then
            arrowLeft(r, x + h * 0.15, y + h * 0.5, aw, h * 0.5, WHITE)
            text(r, hp[1], f.bold, h * 0.5, WHITE, x + h * 0.15 + aw * 1.6, y + h * 0.22, w - aw * 2, "left")
        else
            arrowRight(r, x + w - h * 0.15, y + h * 0.5, aw, h * 0.5, WHITE)
            text(r, hp[1], f.bold, h * 0.5, WHITE, x + h * 0.2, y + h * 0.22, w - aw * 2, "left")
        end
        return
    end
    local sign = SIGNS[name]
    if sign ~= nil then
        local head, color, lines = sign[1], sign[2], sign[3]
        rect(r, x, y, w, h, WHITE); frameRect(r, x, y, w, h, h * 0.025, BLACK)
        rect(r, x + h * 0.025, y + h * 0.025, w - h * 0.05, h * 0.26, color)
        text(r, head, f.bold, h * 0.18, if color == YELLOW or color == ORANGE then BLACK else WHITE, x, y + h * 0.05, w, "center")
        -- Lines share the space under the header, so long signs shrink rather than run off the bottom.
        local step = math.min(0.17, 0.6 / #lines)
        for i: number, line: string in lines do
            text(r, line, f.bold, h * math.min(0.12, step * 0.72), BLACK, x, y + h * (0.34 + (i - 1) * step), w, "center")
        end
        return
    end
    if name == "Label Data Hall Sign" then
        -- The data hall's lit sign: white letters on a dark panel with a blue rule.
        rect(r, x, y, w, h, Color.rgb(22, 28, 36))
        rect(r, x + w * 0.04, y + h * 0.78, w * 0.92, h * 0.04, Color.rgb(40, 140, 230))
        text(r, "DATA HALL 01", f.bold, h * 0.56, WHITE, x, y + h * 0.12, w, "center")
        return
    end
    if name == "Label Station Header" then
        rect(r, x, y, w, h, Color.rgb(0, 122, 61))
        text(r, "REFRIGERANT SAFETY STATION", f.bold, h * 0.62, WHITE, x, y + h * 0.16, w, "center")
        return
    end
    if name == "Label SCBA Door" then
        rect(r, x, y, w, h, YELLOW)
        text(r, "SCBA", f.bold, h * 0.5, BLACK, x, y + h * 0.06, w, "center")
        text(r, "SELF-CONTAINED BREATHING APPARATUS", f.bold, h * 0.17, BLACK, x, y + h * 0.66, w, "center")
        return
    end
    if name == "Label SDS Box" then
        rect(r, x, y, w, h, YELLOW); frameRect(r, x, y, w, h, h * 0.04, BLACK)
        text(r, "SDS", f.bold, h * 0.42, BLACK, x, y + h * 0.1, w, "center")
        text(r, "SAFETY DATA SHEETS", f.bold, h * 0.11, BLACK, x, y + h * 0.58, w, "center")
        text(r, "R-1233zd(E) · OIL", f.body, h * 0.1, BLACK, x, y + h * 0.74, w, "center")
        return
    end
    if name == "Label SCBA Tag" then
        rect(r, x, y, w, h, YELLOW); disc(r, x + w * 0.5, y + h * 0.07, w * 0.09, BLACK)
        text(r, "SCBA", f.bold, w * 0.2, BLACK, x, y + h * 0.15, w, "center")
        text(r, "MONTHLY", f.bold, w * 0.15, BLACK, x, y + h * 0.25, w, "center")
        for i, d in { "06/02", "07/01", "08/04", "09/02", "10/01" } do
            local ry = y + h * (0.4 + (i - 1) * 0.115)
            rect(r, x + w * 0.1, ry + h * 0.09, w * 0.8, h * 0.008, BLACK)
            text(r, d .. "  OK", f.mono, w * 0.12, BLACK, x + w * 0.1, ry, w * 0.8)
        end
        return
    end
    if string.sub(name, 1, 12) == "Label Rating" then
        -- Monorail capacity marking, stencilled on the beam's web.
        rect(r, x, y, w, h, YELLOW)
        text(r, "MONORAIL   CAPACITY 2 TON (1814 kg)", f.bold, h * 0.5, BLACK, x, y + h * 0.2, w, "center")
        return
    end
    if string.sub(name, 1, 9) == "Label Tag" then
        rect(r, x, y, w, h, Color.rgb(28, 64, 120))
        text(r, string.sub(name, 11), f.bold, h * 0.62, WHITE, x, y + h * 0.14, w, "center")
        return
    end
    if name == "Label MCC" then
        rect(r, x, y, w, h, Color.rgb(30, 34, 40)); frameRect(r, x, y, w, h, h * 0.05, Color.rgb(150, 156, 164))
        text(r, "MCC-1   MOTOR CONTROL CENTER   480 V 3 PH", f.bold, h * 0.52, WHITE, x, y + h * 0.2, w, "center")
        return
    end
    if string.sub(name, 1, 21) == "Label Floor Tube Pull" or name == "Label Floor Keep Clear" then
        -- Stencilled floor text: yellow on a transparent ground (the floor shows through).
        local s1 = if string.sub(name, 1, 21) == "Label Floor Tube Pull" then "TUBE PULL CLEARANCE - KEEP CLEAR" else "PUMP SERVICE AREA - KEEP CLEAR"
        text(r, s1, f.bold, h * 0.42, YELLOW, x, y + h * 0.26, w, "center")
        return
    end
    if name == "Label Sign Eyewash" then
        -- Safe-condition sign (ANSI Z535 / ISO 7010 E011 style): white on green, an eye under a water spray.
        local SAFE = Color.rgb(0, 132, 80)
        rect(r, x, y, w, h, SAFE); frameRect(r, x + w * 0.04, y + w * 0.04, w * 0.92, h - w * 0.08, w * 0.02, WHITE)
        local cx, cy, ew = x + w * 0.5, y + h * 0.36, w * 0.3
        local eye = Path.new()
        eye:moveTo(Vector.xy(cx - ew, cy))
        eye:cubicTo(Vector.xy(cx - ew * 0.45, cy - ew * 0.62), Vector.xy(cx + ew * 0.45, cy - ew * 0.62), Vector.xy(cx + ew, cy))
        eye:cubicTo(Vector.xy(cx + ew * 0.45, cy + ew * 0.62), Vector.xy(cx - ew * 0.45, cy + ew * 0.62), Vector.xy(cx - ew, cy))
        eye:close()
        r:drawPath(eye, Paint.with({ color = WHITE }))
        disc(r, cx, cy, ew * 0.27, SAFE)
        disc(r, cx, cy, ew * 0.11, WHITE)
        -- water drops between the eye and the nozzle below it
        local function drop(dx: number, dy: number, rad: number)
            local p = Path.new()
            p:moveTo(Vector.xy(dx, dy - rad * 2.2))
            p:cubicTo(Vector.xy(dx + rad * 0.4, dy - rad * 1.2), Vector.xy(dx + rad, dy - rad * 0.6), Vector.xy(dx + rad, dy))
            p:cubicTo(Vector.xy(dx + rad, dy + rad * 1.35), Vector.xy(dx - rad, dy + rad * 1.35), Vector.xy(dx - rad, dy))
            p:cubicTo(Vector.xy(dx - rad, dy - rad * 0.6), Vector.xy(dx - rad * 0.4, dy - rad * 1.2), Vector.xy(dx, dy - rad * 2.2))
            r:drawPath(p, Paint.with({ color = WHITE }))
        end
        drop(cx, y + h * 0.53, w * 0.03)
        drop(cx - w * 0.12, y + h * 0.55, w * 0.025)
        drop(cx + w * 0.12, y + h * 0.55, w * 0.025)
        rect(r, cx - w * 0.08, y + h * 0.6, w * 0.16, h * 0.022, WHITE)
        rect(r, cx - w * 0.02, y + h * 0.62, w * 0.04, h * 0.035, WHITE)
        text(r, "EMERGENCY", f.bold, h * 0.075, WHITE, x, y + h * 0.075, w, "center")
        text(r, "EYEWASH", f.bold, h * 0.12, WHITE, x, y + h * 0.69, w, "center")
        text(r, "STATION", f.bold, h * 0.06, WHITE, x, y + h * 0.84, w, "center")
        return
    end
    if name == "Label Eyewash Push" then
        rect(r, x, y, w, h, Color.rgb(38, 166, 76)); frameRect(r, x, y, w, h, h * 0.05, WHITE)
        text(r, "PUSH", f.bold, h * 0.34, WHITE, x, y + h * 0.2, w, "center")
        text(r, "FOR WATER", f.bold, h * 0.13, WHITE, x, y + h * 0.62, w, "center")
        return
    end
    if name == "Label Eyewash Tag" then
        rect(r, x, y, w, h, YELLOW); disc(r, x + w * 0.5, y + h * 0.08, w * 0.08, BLACK)
        text(r, "INSPECTED", f.bold, w * 0.15, BLACK, x, y + h * 0.17, w, "center")
        text(r, "WEEKLY", f.bold, w * 0.15, BLACK, x, y + h * 0.27, w, "center")
        for i, d in { "09/15", "09/22", "09/29", "10/06", "10/13" } do
            local ry = y + h * (0.42 + (i - 1) * 0.11)
            rect(r, x + w * 0.1, ry + h * 0.085, w * 0.8, h * 0.008, BLACK)
            text(r, d .. "  OK", f.mono, w * 0.11, BLACK, x + w * 0.1, ry, w * 0.8)
        end
        return
    end
    if name == "Label Alarm Silence" then
        rect(r, x, y, w, h, RED); frameRect(r, x, y, w, h, h * 0.05, WHITE)
        text(r, "PLANT ALARM", f.bold, h * 0.2, WHITE, x, y + h * 0.12, w, "center")
        text(r, "SILENCE", f.bold, h * 0.42, WHITE, x, y + h * 0.36, w, "center")
        return
    end
    if name == "Label Alarm Silence Push" then
        rect(r, x, y, w, h, WHITE); frameRect(r, x, y, w, h, h * 0.06, BLACK)
        text(r, "PUSH TO SILENCE", f.bold, h * 0.5, BLACK, x, y + h * 0.22, w, "center")
        return
    end
    if name == "Label Exit" then
        rect(r, x, y, w, h, Color.rgb(8, 16, 10))
        text(r, "EXIT", f.bold, h * 0.72, Color.rgb(40, 255, 110), x, y + h * 0.1, w, "center")
        return
    end
    rect(r, x, y, w, h, WHITE)
end

local function clipTo(r: Renderer, c: Cell)
    local p = Path.new()
    p:moveTo(Vector.xy(c.x, c.y)); p:lineTo(Vector.xy(c.x + c.w, c.y)); p:lineTo(Vector.xy(c.x + c.w, c.y + c.h)); p:lineTo(Vector.xy(c.x, c.y + c.h)); p:close()
    r:clipPath(p)
end

function Art.paintLabels(r: Renderer, cells: { Cell }, fonts: Fonts)
    for _, c in cells do
        if c.tex == 1 then
            r:save(); clipTo(r, c); paintLabel(r, c, fonts); r:restore()
        end
    end
end

-- ---------------------------------------------------------------------------
-- Telemetry: a running plant at about 70% load, wandering gently
-- ---------------------------------------------------------------------------

-- Overrides a training scenario lays over the live screens and gauges (sim.luau).
export type Drive = { hz: number, state: string } -- state: "run", "stop" or "fault"
export type Effects = {
    chiller: number?, -- which chiller the effects below belong to (1 by default)
    status: string?, tone: string?, -- HMI header and its light: "ok", "warn" or "bad"
    limit: string?, -- shown after LOAD when the chiller is holding capacity back
    alarmText: string?,
    drives: { [number]: Drive }?, -- VFD screens 1-4
    gauges: { [string]: number }?, -- dial values by face name, kPa
    monitor: string?, -- refrigerant monitor state
}

export type Telemetry = {
    t: number, load: number, lchw: number, echw: number, ecw: number, lcw: number,
    kw: number, amps: number, ppm: number, hz1: number, hz2: number, trend: { number }, trendTimer: number,
    base: any, -- the plant before any scenario touched it (the other chillers read these)
    baseTrend: { number },
    fx: Effects?,
}

local function wander(t: number, seed: number): number
    return math.sin(t * 0.11 + seed) * 0.6 + math.sin(t * 0.37 + seed * 2.3) * 0.3 + math.sin(t * 1.3 + seed * 5.1) * 0.1
end

function Art.telemetry(): Telemetry
    local trend = table.create(60, 44.0)
    return { t = 0, load = 0.7, lchw = 44.0, echw = 54.0, ecw = 85.0, lcw = 94.5, kw = 280, amps = 360, ppm = 2,
        hz1 = 52, hz2 = 48, trend = trend, trendTimer = 0, base = {}, baseTrend = table.create(60, 44.0) }
end

function Art.step(s: Telemetry, dt: number)
    s.t += dt
    local t = s.t
    s.load = 0.70 + 0.05 * wander(t, 1.0)
    s.lchw = 44.0 + 0.35 * wander(t, 2.0)
    s.echw = s.lchw + 10.0 * s.load / 0.7 + 0.2 * wander(t, 3.0)
    s.ecw = 85.0 + 0.6 * wander(t, 4.0)
    s.lcw = s.ecw + 9.5 * s.load / 0.7
    s.kw = 400 * s.load + 6 * wander(t, 5.0)
    s.amps = s.kw * 1.29
    s.ppm = math.max(0, 2 + 1.5 * wander(t, 6.0))
    s.hz1 = 52 + 1.2 * wander(t, 7.0)
    s.hz2 = 48 + 1.0 * wander(t, 8.0)
    s.base = { load = s.load, lchw = s.lchw, echw = s.echw, ecw = s.ecw, lcw = s.lcw, kw = s.kw, amps = s.amps }
end

-- The HMI's trend of leaving chilled water, after any scenario overrides.
function Art.stepTrend(s: Telemetry, dt: number)
    s.trendTimer += dt
    if s.trendTimer > 1 then
        s.trendTimer = 0
        table.remove(s.trend, 1)
        table.insert(s.trend, s.lchw)
        table.remove(s.baseTrend, 1)
        table.insert(s.baseTrend, s.base.lchw or 44.0)
    end
end

-- Pressure in kPa at each gauge, with a small needle flutter.
type Gauge = { value: number, max: number, unit: string }
local function gauge(value: number): Gauge return { value = value, max = 600, unit = "kPa" } end
local GAUGES: { [string]: Gauge } = {
    ["Chilled Water Supply Gauge Faces"] = gauge(380), ["Chilled Water Return Gauge Faces"] = gauge(330),
    ["Condenser Water Supply Gauge Faces"] = gauge(300), ["Condenser Water Return Gauge Faces"] = gauge(250),
    ["CHW Pump 1 Gauge Face"] = gauge(420), ["CHW Pump 2 Gauge Face"] = gauge(0),   -- duty pump runs, standby is still
    ["CW Pump 1 Gauge Face"] = gauge(360), ["CW Pump 2 Gauge Face"] = gauge(0),
    ["CHWP-1 Suction Gauge Face"] = gauge(150), ["CHWP-2 Suction Gauge Face"] = gauge(150),   -- suction sees system static pressure
    ["CWP-1 Suction Gauge Face"] = gauge(90), ["CWP-2 Suction Gauge Face"] = gauge(90),
}

-- ---------------------------------------------------------------------------
-- Live screens
-- ---------------------------------------------------------------------------

local SCREEN_BG = Color.rgb(8, 14, 22)
local DIM = Color.rgb(120, 140, 160)
local TEAL = Color.rgb(70, 220, 200)
local AMBER = Color.rgb(255, 176, 40)

-- Which chiller a name belongs to: "CH-2 ..." or "... CH-3"; CH-1 otherwise.
function Art.chillerNum(name: string): number
    local d = string.match(name, "CH%-(%d)")
    return if d ~= nil then tonumber(d) or 1 else 1
end

-- One chiller's readings. CH-1 is the telemetry itself; CH-2 runs alongside it at a slightly
-- lower load; CH-3 is the standby machine. A scenario's effects (fx) belong to fx.chiller (1 by default).
function Art.chillerView(s: Telemetry, n: number): Telemetry
    local fxN = if s.fx ~= nil and s.fx.chiller ~= nil then s.fx.chiller else 1
    if n == fxN then return s end
    local b = s.base
    local v: any = table.clone(s)
    v.fx = nil
    if b.lchw == nil then return v end
    if n == 3 then
        v.load, v.kw, v.amps = 0, 0, 0
        v.lchw = 53.2 + 0.1 * math.sin(s.t * 0.2); v.echw = 53.6 + 0.1 * math.sin(s.t * 0.17)
        v.ecw = 84.0; v.lcw = 84.3
        v.trend = table.create(#s.trend, v.lchw)
    else
        local k = if n == 2 then 0.93 else 1.0
        local off = if n == 2 then 0.15 else 0
        v.load = b.load * k; v.kw = b.kw * k; v.amps = b.amps * k
        v.lchw = b.lchw + off; v.echw = v.lchw + (b.echw - b.lchw) * k; v.ecw = b.ecw; v.lcw = b.ecw + (b.lcw - b.ecw) * k
        local t = {}
        for i, x in s.baseTrend do t[i] = x + off end
        v.trend = t
    end
    return v
end

local function paintHmi(r: Renderer, c: Cell, f: Fonts, s0: Telemetry)
    local x, y, w, h = c.x, c.y, c.w, c.h
    local n = Art.chillerNum(c.name)
    local s = Art.chillerView(s0, n)
    rect(r, x, y, w, h, SCREEN_BG)
    rect(r, x, y, w, h * 0.12, Color.rgb(18, 30, 46))
    local fx = s.fx
    local tone = if fx ~= nil then fx.tone else nil
    local lamp = if tone == "bad" then Color.rgb(240, 70, 60) elseif tone == "warn" then AMBER else Color.rgb(60, 220, 110)
    disc(r, x + w * 0.04, y + h * 0.06, h * 0.022, lamp)
    local standby = s.load <= 0
    if standby and fx == nil then lamp = AMBER end
    text(r, if fx ~= nil and fx.status ~= nil then fx.status else string.format("CH-%d  %s", n, if standby then "STANDBY" else "RUNNING"), f.bold, h * 0.07, WHITE, x + w * 0.07, y + h * 0.022, w * 0.5)
    local limit = if fx ~= nil and fx.limit ~= nil then "  " .. fx.limit else ""
    text(r, string.format("LOAD %d%%", math.round(s.load * 100)) .. limit, f.mono, h * 0.06, if limit ~= "" then AMBER else TEAL, x + w * 0.5, y + h * 0.028, w * 0.46, "right")
    text(r, "LEAVING CHILLED WATER", f.body, h * 0.05, DIM, x + w * 0.04, y + h * 0.16, w * 0.6)
    text(r, string.format("%.1f°F", s.lchw), f.mono, h * 0.17, WHITE, x + w * 0.04, y + h * 0.21, w * 0.6)
    text(r, "SETPOINT 44.0°F", f.body, h * 0.045, DIM, x + w * 0.04, y + h * 0.40, w * 0.6)
    local rows = {
        { "ENT CHW", string.format("%.1f°F", s.echw) }, { "ENT CW", string.format("%.1f°F", s.ecw) },
        { "LVG CW", string.format("%.1f°F", s.lcw) }, { "POWER", string.format("%d kW", math.round(s.kw)) },
        { "MOTOR", string.format("%d A", math.round(s.amps)) },
    }
    for i, row in rows do
        local ry = y + h * (0.16 + (i - 1) * 0.07)
        text(r, row[1], f.body, h * 0.045, DIM, x + w * 0.62, ry + h * 0.005, w * 0.18)
        text(r, row[2], f.mono, h * 0.05, WHITE, x + w * 0.78, ry, w * 0.19, "right")
    end
    -- Load bar
    local by = y + h * 0.53
    rect(r, x + w * 0.04, by, w * 0.92, h * 0.035, Color.rgb(30, 42, 58))
    rect(r, x + w * 0.04, by, w * 0.92 * s.load, h * 0.035, TEAL)
    -- Leaving chilled water trend, last minute
    local gx, gy, gw, gh = x + w * 0.04, y + h * 0.63, w * 0.92, h * 0.27
    rect(r, gx, gy, gw, gh, Color.rgb(12, 20, 30))
    for k = 1, 3 do rect(r, gx, gy + gh * k / 4, gw, 1.5, Color.rgb(28, 40, 56)) end
    -- Centred on 44 °F with a 1.6 °F span, widening to fit a larger swing.
    local lo, hi = 44.0, 44.0
    for _, v in s.trend do lo, hi = math.min(lo, v), math.max(hi, v) end
    local mid = if hi - lo > 1.4 then (lo + hi) / 2 else 44.0
    local span = math.max(1.6, (hi - lo) * 1.25)
    local p = Path.new()
    for i, v in s.trend do
        local px = gx + gw * (i - 1) / (#s.trend - 1)
        local py = gy + gh * math.clamp(0.5 - (v - mid) / span, 0.02, 0.98)
        if i == 1 then p:moveTo(Vector.xy(px, py)) else p:lineTo(Vector.xy(px, py)) end
    end
    r:drawPath(p, Paint.with({ style = "stroke", thickness = h * 0.008, color = TEAL }))
    text(r, "LCHW  LAST 60 s", f.body, h * 0.04, DIM, gx + w * 0.01, gy + h * 0.01, gw * 0.5)
    if fx ~= nil and fx.alarmText ~= nil then
        text(r, fx.alarmText, f.mono, h * 0.04, if tone == "bad" then Color.rgb(255, 110, 90) else AMBER, x + w * 0.04, y + h * 0.93, w * 0.92, "right")
    else
        text(r, "ALARMS 0     12:41", f.mono, h * 0.04, DIM, x + w * 0.04, y + h * 0.93, w * 0.92, "right")
    end
end

local function paintVfd(r: Renderer, c: Cell, f: Fonts, title: string, hz: number, running: boolean, drive: Drive?)
    local x, y, w, h = c.x, c.y, c.w, c.h
    if drive ~= nil then hz, running = drive.hz, drive.state == "run" end
    rect(r, x, y, w, h, Color.rgb(10, 22, 34))
    text(r, title, f.bold, h * 0.16, DIM, x + w * 0.05, y + h * 0.05, w * 0.9)
    if drive ~= nil and drive.state == "fault" then
        text(r, "FAULT", f.mono, h * 0.30, Color.rgb(255, 90, 70), x + w * 0.05, y + h * 0.28, w * 0.9)
        text(r, "F005 MOTOR OVERLOAD", f.mono, h * 0.13, AMBER, x + w * 0.05, y + h * 0.72, w * 0.9)
        return
    end
    text(r, if running then string.format("%.1f Hz", hz) else "STOPPED", f.mono, h * 0.30, if running then WHITE else AMBER, x + w * 0.05, y + h * 0.28, w * 0.9)
    text(r, if running then string.format("%.1f A   %d RPM", hz * 0.38, math.round(hz * 29.4)) else "STANDBY  AUTO", f.mono, h * 0.13, TEAL, x + w * 0.05, y + h * 0.72, w * 0.9)
end

local function paintMonitor(r: Renderer, c: Cell, f: Fonts, s: Telemetry)
    local x, y, w, h = c.x, c.y, c.w, c.h
    rect(r, x, y, w, h, Color.rgb(14, 10, 4))
    text(r, "R-1233zd(E)", f.body, h * 0.16, AMBER, x + w * 0.05, y + h * 0.06, w * 0.9)
    text(r, string.format("%d ppm", math.round(s.ppm)), f.mono, h * 0.34, AMBER, x + w * 0.05, y + h * 0.28, w * 0.9)
    local state = if s.fx ~= nil and s.fx.monitor ~= nil then s.fx.monitor else "NORMAL"
    text(r, state .. "   ALARM 300", f.mono, h * 0.13, Color.rgb(200, 140, 40), x + w * 0.05, y + h * 0.74, w * 0.9)
end

local function paintGauge(r: Renderer, c: Cell, f: Fonts, s: Telemetry)
    local g = GAUGES[c.name] or gauge(0)
    local cx, cy, rad = c.x + c.w / 2, c.y + c.h / 2, math.min(c.w, c.h) / 2
    rect(r, c.x, c.y, c.w, c.h, Color.rgb(200, 170, 90))
    disc(r, cx, cy, rad * 0.96, WHITE)
    -- Ticks over a 270 degree sweep, starting lower left
    for k = 0, 12 do
        local a = math.rad(135 + 270 * k / 12)
        local r0, r1 = rad * (if k % 3 == 0 then 0.68 else 0.76), rad * 0.86
        local p = Path.new()
        p:moveTo(Vector.xy(cx + math.cos(a) * r0, cy + math.sin(a) * r0))
        p:lineTo(Vector.xy(cx + math.cos(a) * r1, cy + math.sin(a) * r1))
        r:drawPath(p, Paint.with({ style = "stroke", thickness = rad * (if k % 3 == 0 then 0.05 else 0.03), color = BLACK }))
    end
    local arcGreen = Path.new()
    for k = 0, 8 do
        local a = math.rad(135 + 270 * (0.45 + 0.3 * k / 8))
        local px, py = cx + math.cos(a) * rad * 0.9, cy + math.sin(a) * rad * 0.9
        if k == 0 then arcGreen:moveTo(Vector.xy(px, py)) else arcGreen:lineTo(Vector.xy(px, py)) end
    end
    r:drawPath(arcGreen, Paint.with({ style = "stroke", thickness = rad * 0.06, color = Color.rgb(40, 160, 70) }))
    text(r, g.unit, f.body, rad * 0.22, DIM, cx - rad * 0.5, cy + rad * 0.28, rad, "center")
    -- The needle, with a little flutter while water is moving
    local value = g.value
    local over = if s.fx ~= nil and s.fx.gauges ~= nil then s.fx.gauges[c.name] else nil
    if over ~= nil then value = over end
    if value > 0 then value += 6 * math.sin(s.t * 9.0 + cx) + 3 * math.sin(s.t * 23.0 + cy) end
    local a = math.rad(135 + 270 * math.clamp(value / g.max, 0, 1))
    local needle = Path.new()
    local nx, ny = math.cos(a), math.sin(a)
    needle:moveTo(Vector.xy(cx - ny * rad * 0.05, cy + nx * rad * 0.05))
    needle:lineTo(Vector.xy(cx + nx * rad * 0.8, cy + ny * rad * 0.8))
    needle:lineTo(Vector.xy(cx + ny * rad * 0.05, cy - nx * rad * 0.05))
    needle:close()
    r:drawPath(needle, Paint.with({ color = RED }))
    disc(r, cx, cy, rad * 0.08, BLACK)
end

function Art.paintScreens(r: Renderer, cells: { Cell }, fonts: Fonts, s: Telemetry, tex: number)
    local drives: { [number]: Drive } = if s.fx ~= nil and s.fx.drives ~= nil then s.fx.drives else {}
    for _, c in cells do
        if c.tex == tex then
            r:save(); clipTo(r, c)
            if string.find(c.name, "Control Panel Screen", 1, true) ~= nil then paintHmi(r, c, fonts, s)
            elseif c.name == "VFD Screen 1" then paintVfd(r, c, fonts, "CHWP-1 DRIVE", s.hz1, true, drives[1])
            elseif c.name == "VFD Screen 2" then paintVfd(r, c, fonts, "CHWP-2 DRIVE", 0, false, drives[2])
            elseif c.name == "VFD Screen 3" then paintVfd(r, c, fonts, "CWP-1 DRIVE", s.hz2, true, drives[3])
            elseif c.name == "VFD Screen 4" then paintVfd(r, c, fonts, "CWP-2 DRIVE", 0, false, drives[4])
            elseif c.name == "Refrigerant Monitor Screen" then paintMonitor(r, c, fonts, s)
            else paintGauge(r, c, fonts, s) end
            r:restore()
        end
    end
end

-- Shared drawing helpers, for the training UI (ui.luau).
Art.text = text
Art.rect = rect
Art.frameRect = frameRect
Art.disc = disc

-- Width of a string in pixels at a size, for word wrapping (either font path).
measureText = function(font: FontRef, s: string, size: number): number
    if type(font) == "string" then
        local data = Glyphs[font]
        if data == nil then return #s * size * 0.5 end
        local wsum = 0
        for _, code in utf8.codes(s) do
            local g = data.glyphs[code]
            wsum += if g ~= nil then g.adv else data.upem * 0.5
        end
        return wsum * size / data.upem
    end
    if font == nil or (Text :: any) == nil then return #s * size * 0.5 end
    local t = Text.new()
    t:append(s, { font = font, size = size, paint = Paint.new() })
    t.sizing = "autoWidth"
    local lo, hi = t:bounds()
    return hi.x - lo.x
end
Art.measure = measureText

-- A gauge's simulated reading (kPa), as the dials draw it.
function Art.gaugeValue(name: string, s: Telemetry): number
    -- CH-2 and CH-3 gauges carry their chiller as a prefix ("CH-2 Chilled Water Supply Gauge Faces").
    local n = Art.chillerNum(name)
    local base = string.gsub(name, "^CH%-%d ", "")
    local g = GAUGES[base] or gauge(0)
    local value = g.value
    if n == 3 then value *= 0.5 end -- the standby chiller: valves open, no flow through it
    if n ~= (if s.fx ~= nil and s.fx.chiller ~= nil then s.fx.chiller else 1) then return value + (if value > 0 then 6 * math.sin(s.t * 9.0 + n) else 0) end
    local over = if s.fx ~= nil and s.fx.gauges ~= nil then s.fx.gauges[base] else nil
    if over ~= nil then value = over end
    if value > 0 then value += 6 * math.sin(s.t * 9.0) end
    return value
end

return Art
