-- Data center chiller room: a first-person walkthrough drawn with the Rive GPU API.
--
-- Controls
--   W / S                  walk forward / back
--   Q / E                  step left / right
--   Space                  walk faster
--   Left / Right arrows    turn
--   Up / Down arrows       look up / down
--
-- Units are metres. Y is up. The room spans x -10..10, z -7..7, y 0..4.5.
--
-- The whole room (shell, chiller, pumps, services, labels) is modelled in
-- chiller_hifi.blend and exported as two blobs: scene_vertices.bin (24 bytes
-- a vertex: position f32x3, normal snorm8x4, colour unorm8x4, material
-- unorm8x4) and scene_indices.bin (u32 triangles). scene_meta.luau, exported
-- with them, holds the atlas frames and collision boxes.
--
-- Each frame (after Data Hall 01's renderer):
--   2D canvases   label atlas once, live screen atlas at 6 Hz (art.luau)
--   shadow        depth from overhead, 2048 px, first frames only (static room)
--   pre-pass      camera depth at 1x, for contact AO
--   SSAO          half size, then a separable blur
--   main          4x MSAA, lit by room.wgsl, resolved into the canvas
--   bloom         bright pass and blurs at half and quarter size, added back

-- scene_meta is generated and too large for the type checker (--!nocheck), so its shape is declared here.
type Frame = { origin: { number }, u: { number }, v: { number }, name: string }
type Box = { x0: number, z0: number, x1: number, z1: number }
type Pickable = { pick: string, first: number, count: number, min: { number }, max: { number } }
type Anim = { pivot: { number }, axis: { number }, pick: string }
local Meta: { frames: { Frame }, colliders: { Box }, objects: { Pickable }, anims: { Anim } } = require("scene_meta") :: any
local Art = require("art")
local Training = require("training")
local UI = require("ui")
local Games = require("games")
local Sim = require("sim")

-- ---------------------------------------------------------------------------
-- Scene settings (safe to tweak)
-- ---------------------------------------------------------------------------

local ROOM_X0, ROOM_X1 = -10, 38 -- the plant room and, east of x = 10, the chiller hall
local ROOM_HALF_Z = 7

local EYE_HEIGHT = 1.7
local WALK_SPEED = 2.5 -- metres per second
local RUN_SPEED = 5.0
-- Head bob: the eye dips once per footstep and sways a touch side to side.
local BOB_WALK, BOB_RUN = 0.022, 0.038 -- metres, peak
local STEPS_WALK, STEPS_RUN = 1.9, 2.7 -- footsteps per second
local TURN_SPEED = 1.8 -- radians per second, left / right arrows
local TILT_SPEED = 1.2 -- radians per second, up / down arrows
local BODY_RADIUS = 0.35 -- how close you can get to walls and equipment
local FOV_DEGREES = 70
local NEAR, FAR = 0.05, 110 -- far enough for the data hall across the road

local LIGHT_LEVEL = 1.3 -- each ceiling panel's intensity
local BLOOM_THRESHOLD = 0.86
local BLOOM_NEAR, BLOOM_WIDE = 0.35, 0.45
local PIXEL_BUDGET = 1600000 -- rendered 3D pixels, at most (the crosshair stays sharp)
local SCREEN_TICK_HZ = 12 -- live screens: the HMI and the small screens alternate, so each repaints at 6 Hz

-- Features allowed at all (a cap on the ladder below); profile prints CPU timings.
local PERF = { msaa = true, ssao = true, bloom = true, profile = false }

-- The quality ladder, best first. When frames miss 60 Hz the governor steps
-- down it: resolution first, then bloom, contact AO and MSAA, then resolution again.
type Tier = { res: number, bloom: boolean, ssao: boolean, msaa: boolean }
local TIERS: { Tier } = {
    { res = 1.0, bloom = true, ssao = true, msaa = true },
    { res = 0.9, bloom = true, ssao = true, msaa = true },
    { res = 0.8, bloom = true, ssao = true, msaa = true },
    { res = 0.8, bloom = false, ssao = true, msaa = true },
    { res = 0.7, bloom = false, ssao = true, msaa = true },
    { res = 0.7, bloom = false, ssao = false, msaa = true },
    { res = 0.65, bloom = false, ssao = false, msaa = false },
    { res = 0.55, bloom = false, ssao = false, msaa = false },
    { res = 0.45, bloom = false, ssao = false, msaa = false },
}
-- After Data Hall 01's GOV: watch 1 s windows; 3 frames over 1/52 s in one means step down.
local GOV = { MISS_FRAME = 1 / 52, WINDOW = 1.0, MISS_LIMIT = 3, CALM_RAISE = 8, RAISE_GRACE = 12 }

local CLEAR_WHITE: GPUColor = { 1, 1, 1, 1 }
local CLEAR_BLACK: GPUColor = { 0, 0, 0, 1 }
local CLEAR_ROOM: GPUColor = { 0.10, 0.11, 0.13, 1 }

local SHADOW_SIZE = 2048
local FRAME_UBO_SIZE = 352 + 512 * 16 + 128 * 16
local ANIMS_OFFSET = 352 + 512 * 16
local FRAMES_OFFSET = 352
local LIGHTS_OFFSET = 160
local SHADOW_MATRIX_OFFSET = 96

-- GLFW key codes, as the Rive player reports them.
local KEY_W = 87
local KEY_Q = 81 -- step left
local KEY_S = 83
local KEY_E = 69 -- step right
local KEY_RIGHT = 262
local KEY_LEFT = 263
local KEY_DOWN = 264
local KEY_UP = 265
local KEY_SPACE = 32
local PAGE_SCALE_KEY = 10000 -- see keyboardEvent
local SHOW_HOVER_HINT = false -- names show only when clicked (the inspect panel), not on hover
local SOUND_OFF_KEY = 9000 -- the page's sound toggle, see keyboardEvent
local SOUND_ON_KEY = 9001

local WORLD_LAYOUT: VertexBufferLayout = {
    stride = 24,
    attributes = {
        { format = "float32x3", slot = 0, offset = 0 },
        { format = "snorm8x4", slot = 1, offset = 12 },
        { format = "unorm8x4", slot = 2, offset = 16 },
        { format = "unorm8x4", slot = 3, offset = 20 },
    },
}

-- The linear LED fixtures (lens centres), as modelled in chiller_hifi.blend: 12 in the plant room,
-- 18 in the chiller hall. The shader lights with the 12 nearest the camera (see updateLights).
local LIGHTS = {}
for _, lz in { 4.2, 0.6, -3.1 } do
    for _, lx in { -7.5, -2.5, 2.5, 7.5, 12.5, 17.5, 22.5, 27.5, 32.5 } do
        table.insert(LIGHTS, { lx, 4.598, lz })
    end
end
local SHADER_LIGHTS = 12

-- The dividing wall between the plant room and the hall: only behind the MCC now, ending in a column.
local WALL_BOXES = {
    { x0 = 9.95, z0 = -7.0, x1 = 10.35, z1 = 0.35 },
}

-- The upper level (tools/walkways.py builds the same shapes): the south walkway, two bridges
-- and the stair, as areas with a walking surface rising from y0 at x0 to y1 at x1.
-- s* is where you can stand on it: inset from handrails and walls, extended where it joins the next piece.
type Walk = { x0: number, x1: number, z0: number, z1: number, y0: number, y1: number, stair: boolean?,
    sx0: number, sx1: number, sz0: number, sz1: number }
local WALK: { Walk } = {
    { x0 = -9.4, x1 = 26.8, z0 = 5.6, z1 = 6.9, y0 = 6, y1 = 6, sx0 = -9.15, sx1 = 26.9, sz0 = 5.82, sz1 = 6.62 },
    { x0 = 4.65, x1 = 5.85, z0 = -6.9, z1 = 5.6, y0 = 6, y1 = 6, sx0 = 4.87, sx1 = 5.63, sz0 = -6.65, sz1 = 6.2 },
    { x0 = 20.15, x1 = 21.35, z0 = -6.9, z1 = 5.6, y0 = 6, y1 = 6, sx0 = 20.37, sx1 = 21.13, sz0 = -6.65, sz1 = 6.2 },
    { x0 = 26.8, x1 = 35.8, z0 = 5.6, z1 = 6.9, y0 = 6, y1 = 0, stair = true, sx0 = 26.7, sx1 = 36.3, sz0 = 5.82, sz1 = 6.62 }, -- as wide as the walkway it meets
}
local STEP_UP = 0.55 -- the highest rise you walk onto without noticing
local KEY_R = 82 -- jump
local JUMP_SPEED = 4.2 -- m/s up: about 0.9 m high
local GRAVITY = 9.8

-- Sound sources: a centrifugal compressor and the pump row, quieter with distance.
local LOOP_LENGTH = 6.0
local SOUNDS = {
    { name = "chiller_hum", x = -0.4, y = 1.8, z = -3.2, level = 0.55, falloff = 4.5 },
    { name = "pump_hum", x = -7.2, y = 0.6, z = -5.35, level = 0.45, falloff = 3.5 },
}

-- ---------------------------------------------------------------------------
-- Script state
-- ---------------------------------------------------------------------------

type Loop = { source: AudioSource?, current: AudioSound?, previous: AudioSound?, start: number, volume: number }

type Room = {
    context: Context?,
    shaderWarned: boolean,
    g: any, -- GPU objects, created once the shaders are available
    ready: boolean,

    size: Vector,
    scale: number, -- device pixels per point: the larger of hostScale and pageScale
    hostScale: number, -- from resize
    soundOn: boolean, -- the page's sound toggle
    pageScale: number, -- reported by the web page (keyboardEvent)
    quality: number,
    tier: number,
    tierCap: number,
    lastRaise: number,
    bloomOn: boolean,
    ssaoOn: boolean,
    screenTex: number,
    targetsDirty: boolean,
    width: number,
    height: number,

    camX: number,
    camZ: number,
    yaw: number,
    pitch: number,
    keys: { [number]: boolean },

    time: number,
    screenTimer: number,
    labelsPainted: boolean,
    shadowFrames: number,
    slowFrames: number,
    slowTimer: number,
    calmTimer: number,
    telemetry: Art.Telemetry,
    cells: { Art.Cell },
    fonts: Art.Fonts,
    loops: { Loop },
    alarmSource: AudioSource?, -- the plant alarm horn, looped while a scenario alarm is unsilenced
    alarmSound: AudioSound?,
    alarmNext: number,
    vm: any, vmReport: any, vmSync: any, reportSeq: number, reportLog: { string }, lastSync: string,
    bobPhase: number, -- footstep cycle
    bobAmp: number, -- eases in and out as walking starts and stops
    eyeY: number, -- feet plus EYE_HEIGHT plus the bob
    feetY: number, -- the floor (0), a stair or a walkway (6)
    jumpH: number, -- height above the ground while jumping
    jumpV: number,
    swayX: number, -- sideways sway of the eye (world x, z)
    swayZ: number,
    prof: { frames: number, screens: number, screensMax: number, encode: number, encodeMax: number },
    aoCleared: boolean,

    crosshair: Path,
    crosshairPaint: Paint,
    ui: any, -- training interface state (see the Training section)
}

local function writeParams(buf: GPUBuffer, a: number, b: number, c: number, d: number)
    local bytes = buffer.create(16)
    buffer.writef32(bytes, 0, a); buffer.writef32(bytes, 4, b); buffer.writef32(bytes, 8, c); buffer.writef32(bytes, 12, d)
    buf:write(bytes)
end


-- Fonts: context:font where the runtime has it, else decoded from the font blobs.
local function loadFont(context: Context, name: string): Font?
    local ok, font = pcall(function(): Font?
        return (context :: any):font(name)
    end)
    if ok and font ~= nil then
        return font
    end
    local blob = context:blob(name .. "_ttf")
    if blob ~= nil then
        local decoded, f = pcall(function(): Font?
            return Font.decode(blob.data)
        end)
        if decoded then
            return f
        end
    end
    return nil
end

local function loadFonts(context: Context): Art.Fonts
    local mono = loadFont(context, "Mono")
    if mono ~= nil then
        local ok, weighted = pcall(function(): Font
            return (mono :: Font):withOptions({ wght = 500 })
        end)
        if ok then mono = weighted end
    end
    local body, bold = loadFont(context, "Barlow"), loadFont(context, "BarlowBold")
    if body == nil or bold == nil or mono == nil then
        print("no font API here: drawing text from baked outlines (glyphs.luau)")
        return { body = "Barlow", bold = "BarlowBold", mono = "Mono" }
    end
    return { body = body, bold = bold, mono = mono }
end

-- ---------------------------------------------------------------------------
-- GPU setup
-- ---------------------------------------------------------------------------

-- Creates the size-independent GPU resources. Web runtimes can register the
-- shaders a little after init runs, so this is retried from draw until they are there.
-- Writes the 12 fixtures nearest the camera into the frame uniforms (the hall has 30).
local function updateLights(self: Room, g: any)
    local order: { { i: number, d: number } } = {}
    for i, l in LIGHTS do
        local dx, dz = l[1] - self.camX, l[3] - self.camZ
        table.insert(order, { i = i, d = dx * dx + dz * dz })
    end
    table.sort(order, function(a: { i: number, d: number }, b: { i: number, d: number }): boolean return a.d < b.d end)
    for k = 1, SHADER_LIGHTS do
        local l = LIGHTS[order[k].i]
        local o = LIGHTS_OFFSET + (k - 1) * 16
        buffer.writef32(g.bytes, o, l[1]); buffer.writef32(g.bytes, o + 4, l[2]); buffer.writef32(g.bytes, o + 8, l[3]); buffer.writef32(g.bytes, o + 12, LIGHT_LEVEL)
    end
end

local function setupGpu(self: Room, context: Context): boolean
    if self.ready then
        return true
    end
    local lit = context:shader("room")
    local shadowShader = context:shader("shadow")
    local ssaoShader = context:shader("ssao")
    local blurShader = context:shader("blur")
    local compShader = context:shader("bloomcomp")
    if lit == nil or shadowShader == nil or ssaoShader == nil or blurShader == nil or compShader == nil then
        if not self.shaderWarned then
            print("waiting for the shaders (room, shadow, ssao, blur, bloomcomp) - retrying each frame")
            self.shaderWarned = true
        end
        return false
    end
    local verts = context:blob("scene_vertices")
    local idx = context:blob("scene_indices")
    if verts == nil or idx == nil then
        print("ERROR: scene_vertices / scene_indices blobs are missing - re-export from chiller_hifi.blend")
        return false
    end

    local g: any = {}
    g.maxSamples = if PERF.msaa and context:features().maxSamples >= 4 then 4 else 1
    g.samples = g.maxSamples
    local canvas = context:gpuCanvas()
    g.canvas = canvas
    local format = canvas.format

    local frameLayout = GPUBindGroupLayout.new({ shader = lit, groupIndex = 0 })
    local surfaceLayout = GPUBindGroupLayout.new({ shader = lit, groupIndex = 1 })
    g.contactLayout = GPUBindGroupLayout.new({ shader = lit, groupIndex = 2 })
    local depthState: DepthStencilState = { format = "depth32float", compare = "less", write = true }
    local additive: BlendState = { srcColor = "one", dstColor = "one", srcAlpha = "zero", dstAlpha = "one" }

    -- The lit pipeline at 4x and 1x, so the governor can drop MSAA without a stall.
    g.litPipelines = {}
    for _, samples in { 1, g.maxSamples } do
        g.litPipelines[samples] = GPUPipeline.new({
            vertex = lit,
            fragment = { module = lit, entryPoint = "fs" },
            vertexLayout = { WORLD_LAYOUT },
            bindGroupLayouts = { frameLayout, surfaceLayout, g.contactLayout },
            colorTargets = { { format = format } },
            depthStencil = depthState,
            cullMode = "none",
            sampleCount = samples,
        })
    end
    -- The training glow: the target's triangles again, added over the lit pass.
    g.glowPipelines = {}
    g.shellPipelines = {}
    for _, samples in { 1, g.maxSamples } do
        g.shellPipelines[samples] = GPUPipeline.new({
            vertex = { module = lit, entryPoint = "vsGlowShell" },
            fragment = { module = lit, entryPoint = "fsGlowShell" },
            vertexLayout = { WORLD_LAYOUT },
            bindGroupLayouts = { frameLayout, surfaceLayout, g.contactLayout },
            colorTargets = { { format = format, blend = additive } },
            depthStencil = { format = "depth32float", compare = "less-equal", write = false },
            cullMode = "none",
            sampleCount = samples,
        })
        g.glowPipelines[samples] = GPUPipeline.new({
            vertex = lit,
            fragment = { module = lit, entryPoint = "fsGlow" },
            vertexLayout = { WORLD_LAYOUT },
            bindGroupLayouts = { frameLayout, surfaceLayout, g.contactLayout },
            colorTargets = { { format = format, blend = additive } },
            depthStencil = { format = "depth32float", compare = "less-equal", write = false },
            cullMode = "none",
            sampleCount = samples,
        })
    end
    g.shadowPipeline = GPUPipeline.new({
        vertex = { module = shadowShader, entryPoint = "vs" },
        vertexLayout = { WORLD_LAYOUT },
        bindGroupLayouts = { frameLayout },
        depthStencil = { format = "depth32float", compare = "less", write = true, depthBias = 2, depthBiasSlopeScale = 2 },
        cullMode = "none",
    })
    g.depthPipeline = GPUPipeline.new({
        vertex = { module = shadowShader, entryPoint = "vsCamera" },
        vertexLayout = { WORLD_LAYOUT },
        bindGroupLayouts = { frameLayout },
        depthStencil = depthState,
        cullMode = "none",
    })
    g.ssaoPipeline = GPUPipeline.new({ vertex = ssaoShader, fragment = ssaoShader, vertexLayout = {}, colorTargets = { { format = "rgba8unorm" } } })
    g.blurPipeline = GPUPipeline.new({ vertex = blurShader, fragment = blurShader, vertexLayout = {}, colorTargets = { { format = "rgba8unorm" } } })
    g.bloomPipeline = GPUPipeline.new({ vertex = compShader, fragment = compShader, vertexLayout = {}, colorTargets = { { format = format, blend = additive } } })
    g.ssaoLayout = g.ssaoPipeline:getBindGroupLayout(0)
    g.blurLayout = g.blurPipeline:getBindGroupLayout(0)
    g.compLayout = g.bloomPipeline:getBindGroupLayout(0)

    g.vertexBuffer = GPUBuffer.new({ size = verts.size, usage = "vertex", data = verts.data, immutable = true, label = "scene vertices" })
    g.indexBuffer = GPUBuffer.new({ size = idx.size, usage = "index", data = idx.data, immutable = true, label = "scene indices" })
    g.indexCount = idx.size // 4
    g.vdata, g.idata = verts.data, idx.data   -- kept for click picking against the real triangles
    g.panelCanvas = context:canvas({ width = UI.PANEL_W, height = UI.PANEL_MAX_H })
    g.toolbarCanvas = context:canvas({ width = UI.TOOLBAR_W, height = UI.TOOLBAR_H })
    g.hintCanvas = context:canvas({ width = 560, height = 30 })
    g.cardCanvas = context:canvas({ width = UI.CARD_W, height = UI.CARD_MAX_H })
    g.bannerCanvas = context:canvas({ width = UI.BANNER_W, height = UI.BANNER_H })
    g.toastCanvas = context:canvas({ width = UI.TOAST_W, height = UI.TOAST_H })
    g.tagCanvas = context:canvas({ width = UI.TAG_W, height = UI.TAG_H })
    g.gameCanvas = context:canvas({ width = Games.W, height = Games.H })

    g.ubo = GPUBuffer.new({ size = FRAME_UBO_SIZE, usage = "uniform", label = "frame" })
    g.bytes = buffer.create(FRAME_UBO_SIZE)
    g.frameGroup = GPUBindGroup.new({ layout = frameLayout, ubos = { { slot = 0, buffer = g.ubo } } })

    local shadowTexture = GPUTexture.new({ width = SHADOW_SIZE, height = SHADOW_SIZE, format = "depth32float", renderTarget = true, label = "shadow" })
    g.shadowView = shadowTexture:view()
    g.atlas = {}
    for tex, size in Art.SIZES do
        g.atlas[tex] = context:canvas({ width = size[1], height = size[2] })
    end
    g.linearSampler = GPUSampler.new({ min = "linear", mag = "linear", wrapU = "clamp-to-edge", wrapV = "clamp-to-edge" })
    g.surfaceGroup = GPUBindGroup.new({
        layout = surfaceLayout,
        textures = {
            { slot = 0, view = shadowTexture:view({ aspect = "depth-only" }) },
            { slot = 2, view = g.atlas[1].image:view() },
            { slot = 4, view = g.atlas[2].image:view() },
            { slot = 5, view = g.atlas[3].image:view() },
        },
        samplers = {
            { slot = 1, sampler = GPUSampler.new({ min = "linear", mag = "linear", mipmap = "nearest", compare = "less-equal" }) },
            { slot = 3, sampler = g.linearSampler },
        },
    })

    g.ssaoParams = GPUBuffer.new({ size = 32, usage = "uniform" })
    g.aoBlurParams = { GPUBuffer.new({ size = 16, usage = "uniform" }), GPUBuffer.new({ size = 16, usage = "uniform" }) }
    g.bloomParams = {}
    for _ = 1, 7 do
        table.insert(g.bloomParams, GPUBuffer.new({ size = 16, usage = "uniform" }))
    end

    -- Atlas frames: each quad's world frame and its cell, written once into the frame UBO.
    self.cells = Art.layout(Meta.frames)
    for i, f in Meta.frames do
        local c = self.cells[i]
        if c ~= nil and i <= 128 then -- the frame UBO holds 128 (room.wgsl frames array)
            local o = FRAMES_OFFSET + (i - 1) * 64
            local W, H = Art.SIZES[c.tex][1], Art.SIZES[c.tex][2]
            local u2 = f.u[1] * f.u[1] + f.u[2] * f.u[2] + f.u[3] * f.u[3]
            local v2 = f.v[1] * f.v[1] + f.v[2] * f.v[2] + f.v[3] * f.v[3]
            local values = {
                f.origin[1], f.origin[2], f.origin[3], c.tex,
                f.u[1], f.u[2], f.u[3], 1 / math.max(u2, 1e-6),
                f.v[1], f.v[2], f.v[3], 1 / math.max(v2, 1e-6),
                c.x / W, c.y / H, c.w / W, c.h / H,
            }
            for k, value in values do
                buffer.writef32(g.bytes, o + (k - 1) * 4, value)
            end
        end
    end
    updateLights(self, g)
    -- The shadow light: straight down, an orthographic box around the room. Its near plane sits
    -- just under the light fixtures (y = 4.56), so the fixtures, deck, beams, duct and the highest pipes cast nothing.
    local lightView = Mat4.lookAt(Vector.xyz(14, 20, 0), Vector.xyz(14, 0, 0), Vector.xyz(0, 0, 1))
    local lightProj = Mat4.ortho(-26, 26, -26, 26, 20 - 4.40, 40); -- starts under the troffers and diffusers (4.44 m): light sources cast nothing
    (lightProj * lightView):writeToBuffer(g.bytes, SHADOW_MATRIX_OFFSET)

    self.fonts = loadFonts(context)
    for _, s in SOUNDS do
        table.insert(self.loops, { source = context:audio(s.name), current = nil, previous = nil, start = 0, volume = 0 })
    end
    self.alarmSource = context:audio("alarm")

    self.g = g
    self.ready = true
    self.targetsDirty = true
    print(`chiller room ready: {g.indexCount // 3} triangles, {#Meta.frames} atlas frames, {g.samples}x MSAA`)
    return true
end

-- (Re)creates everything that depends on the canvas size.
local function buildTargets(self: Room)
    local g = self.g
    local canvas = g.canvas
    local full = self.size.x * self.size.y * self.scale * self.scale
    local cap = math.clamp(math.sqrt(PIXEL_BUDGET / math.max(full, 1)), 0.45, 1)
    local scale = self.scale * math.min(self.quality, cap)
    local pw = math.max(1, math.floor(self.size.x * scale))
    local ph = math.max(1, math.floor(self.size.y * scale))
    self.width, self.height = pw, ph
    canvas:resize(pw, ph)

    if g.samples > 1 then
        g.msaaView = GPUTexture.new({ width = pw, height = ph, format = canvas.format, renderTarget = true, sampleCount = g.samples, label = "msaa" }):view()
    end
    g.depthView = GPUTexture.new({ width = pw, height = ph, format = "depth32float", renderTarget = true, sampleCount = g.samples, label = "depth" }):view()
    local pre = GPUTexture.new({ width = pw, height = ph, format = "depth32float", renderTarget = true, label = "prepass" })
    g.prepassView = pre:view()
    local preSample = pre:view({ aspect = "depth-only" })

    local function target(w: number, h: number): GPUTextureView
        return GPUTexture.new({ width = w, height = h, format = "rgba8unorm", renderTarget = true }):view()
    end
    local hw, hh = math.max(1, math.ceil(pw / 2)), math.max(1, math.ceil(ph / 2))
    local qw, qh = math.max(1, math.ceil(pw / 4)), math.max(1, math.ceil(ph / 4))

    -- Contact AO at half size: SSAO into ao1, blurred ao1 -> ao2 -> ao1.
    local ao1, ao2 = target(hw, hh), target(hw, hh)
    g.aoTargets = { ao1, ao2, ao1 }
    local bytes = buffer.create(32)
    for i, v in { pw, ph, math.tan(math.rad(FOV_DEGREES) / 2), pw / ph, NEAR, FAR, 0.35, 1.5 } do
        buffer.writef32(bytes, (i - 1) * 4, v)
    end
    g.ssaoParams:write(bytes)
    g.ssaoGroup = GPUBindGroup.new({ layout = g.ssaoLayout, textures = { { slot = 0, view = preSample } }, ubos = { { slot = 1, buffer = g.ssaoParams } } })
    writeParams(g.aoBlurParams[1], 1 / hw, 0, 1, 0)
    writeParams(g.aoBlurParams[2], 0, 1 / hh, 1, 0)
    g.aoBlurGroups = {}
    for i, source in { ao1, ao2 } do
        table.insert(g.aoBlurGroups, GPUBindGroup.new({
            layout = g.blurLayout,
            textures = { { slot = 0, view = source } },
            samplers = { { slot = 1, sampler = g.linearSampler } },
            ubos = { { slot = 2, buffer = g.aoBlurParams[i] } },
        }))
    end
    g.contactGroup = GPUBindGroup.new({ layout = g.contactLayout, textures = { { slot = 0, view = ao1 } } })

    -- Bloom: canvas -> A (bright, half) -> B -> A, A -> C (quarter) -> D -> C, then A + C added back.
    local A, B, Cq, D = target(hw, hh), target(hw, hh), target(qw, qh), target(qw, qh)
    g.bloomTargets = { A, B, A, Cq, D, Cq }
    local sources = { canvas:colorView(), A, B, A, Cq, D }
    local P = g.bloomParams
    writeParams(P[1], 1 / pw, 1 / ph, 0, BLOOM_THRESHOLD)
    writeParams(P[2], 1 / hw, 0, 1, 0)
    writeParams(P[3], 0, 1 / hh, 1, 0)
    writeParams(P[4], 1 / hw, 1 / hh, 0, -1)
    writeParams(P[5], 1 / qw, 0, 1, 0)
    writeParams(P[6], 0, 1 / qh, 1, 0)
    writeParams(P[7], BLOOM_NEAR, BLOOM_WIDE, 0, 0)
    g.bloomGroups = {}
    for i = 1, 6 do
        table.insert(g.bloomGroups, GPUBindGroup.new({
            layout = g.blurLayout,
            textures = { { slot = 0, view = sources[i] } },
            samplers = { { slot = 1, sampler = g.linearSampler } },
            ubos = { { slot = 2, buffer = P[i] } },
        }))
    end
    g.bloomComposite = GPUBindGroup.new({
        layout = g.compLayout,
        textures = { { slot = 0, view = A }, { slot = 1, view = Cq } },
        samplers = { { slot = 2, sampler = g.linearSampler } },
        ubos = { { slot = 3, buffer = P[7] } },
    })
    -- UI canvases at device scale, so text stays sharp at 2x.
    local us = math.max(1, self.scale)
    g.panelCanvas:resize(math.ceil(UI.PANEL_W * us), math.ceil(UI.PANEL_MAX_H * us))
    g.toolbarCanvas:resize(math.ceil(UI.TOOLBAR_W * us), math.ceil(UI.TOOLBAR_H * us))
    g.hintCanvas:resize(math.ceil(560 * us), math.ceil(30 * us))
    g.cardCanvas:resize(math.ceil(UI.CARD_W * us), math.ceil(UI.CARD_MAX_H * us))
    g.bannerCanvas:resize(math.ceil(UI.BANNER_W * us), math.ceil(UI.BANNER_H * us))
    g.toastCanvas:resize(math.ceil(UI.TOAST_W * us), math.ceil(UI.TOAST_H * us))
    g.tagCanvas:resize(math.ceil(UI.TAG_W * us), math.ceil(UI.TAG_H * us))
    g.gameCanvas:resize(math.ceil(Games.W * us), math.ceil(Games.H * us))
    self.ui.toastDirty, self.ui.tagText = true, ""
    self.ui.panelDirty, self.ui.toolbarDirty, self.ui.hintDirty = true, true, true
    self.ui.cardDirty, self.ui.bannerDirty = true, true
    self.targetsDirty = false
end

function init(self: Room, context: Context): boolean
    self.context = context
    -- The page link (see scene.rml's Progress view model); absent on the first init call.
    local vm = context:viewModel()
    if vm ~= nil then
        self.vm = vm
        self.vmReport = vm:getString("report")
        self.vmSync = vm:getString("sync")
    end
    setupGpu(self, context)
    return true
end

function resize(self: Room, size: Vector, scale: number)
    self.size = size
    self.hostScale = scale
    self.scale = math.max(scale, self.pageScale)
    self.targetsDirty = true
end

-- ---------------------------------------------------------------------------
-- Movement and sound
-- ---------------------------------------------------------------------------

local function held(self: Room, key: number): number
    return if self.keys[key] then 1 else 0
end

-- Keeps the player inside the room and outside every equipment footprint.
local function surfaceAt(w: Walk, x: number): number
    return w.y0 + (w.y1 - w.y0) * math.clamp((x - w.x0) / (w.x1 - w.x0), 0, 1)
end

-- The highest walkable surface under (x, z) that you can step onto from your feet.
local function groundAt(feet: number, x: number, z: number): number
    local best = 0
    for _, w in WALK do
        if x > w.x0 and x < w.x1 and z > math.min(w.z0, w.sz0) and z < math.max(w.z1, w.sz1) then
            local h = surfaceAt(w, x)
            if h <= feet + STEP_UP and h > best then best = h end
        end
    end
    return best
end

-- Whether you may stand at (x, z): up on the walkways only on them (the rails keep you on);
-- on the floor, not under the low end of the stair.
local function canStand(feet: number, x: number, z: number): boolean
    if feet > STEP_UP then
        for _, w in WALK do
            if x > w.sx0 and x < w.sx1 and z > w.sz0 and z < w.sz1 and math.abs(surfaceAt(w, x) - feet) < STEP_UP + 0.3 then
                return true
            end
        end
        return false
    end
    -- On the floor the stair is solid where it's too high to step onto but too low to walk under.
    for _, w in WALK do
        if w.stair and x > w.x0 - BODY_RADIUS and x < w.x1 + BODY_RADIUS and z > w.z0 - BODY_RADIUS and z < w.z1 + BODY_RADIUS then
            local h = surfaceAt(w, x)
            if h > feet + STEP_UP and h < feet + 2.0 then return false end
        end
    end
    return true
end

-- Up on the stair or a walkway, a step that misses every standing area by a little is eased into
-- the nearest one within 0.5 m that still carries you forward (a fifth of the step at least); from a
-- spot you can't stand on (it happens as your feet rise past STEP_UP), into the nearest one at all.
-- Without it you'd stick where the stair meets the walkway, or on the bottom steps near a rail.
local function easeIn(feet: number, ox: number, oz: number, x: number, z: number): (number?, number?)
    if feet <= STEP_UP then return nil, nil end
    local dx, dz = x - ox, z - oz
    local need = if canStand(feet, ox, oz) then 0.2 * (dx * dx + dz * dz) else -math.huge
    local bestD, bestX, bestZ = math.huge, nil, nil
    for _, w in WALK do
        if x > w.sx0 - 0.5 and x < w.sx1 + 0.5 and z > w.sz0 - 0.5 and z < w.sz1 + 0.5 then
            local cx = math.clamp(x, w.sx0 + 0.01, w.sx1 - 0.01)
            local cz = math.clamp(z, w.sz0 + 0.01, w.sz1 - 0.01)
            if (cx - ox) * dx + (cz - oz) * dz >= need and canStand(feet, cx, cz) then
                local d = (cx - x) ^ 2 + (cz - z) ^ 2
                if d < bestD then bestD, bestX, bestZ = d, cx, cz end
            end
        end
    end
    return bestX, bestZ
end

-- On the floor, the part of a stair too high to step onto and too low to walk under is solid (see
-- canStand). Stepping off the side of the low steps can drop you inside it, where every step would be
-- refused: move out to its nearest edge, the way equipment pushes you out.
local function pushOutOfStair(feet: number, x: number, z: number): (number, number)
    for _, w in WALK do
        if not w.stair then continue end
        local z0, z1 = w.z0 - BODY_RADIUS, w.z1 + BODY_RADIUS
        if z <= z0 or z >= z1 then continue end
        local h = surfaceAt(w, x)
        if h > feet + STEP_UP and h < feet + 2.0 then
            local function xAt(y: number): number
                return w.x0 + (y - w.y0) / (w.y1 - w.y0) * (w.x1 - w.x0)
            end
            local xStep, xUnder = xAt(feet + STEP_UP), xAt(feet + 2.0)
            local out = if xStep > xUnder then 0.001 else -0.001
            local best, bx, bz = z - z0, x, z0 - 0.001
            if math.abs(x - xStep) < best then best, bx, bz = math.abs(x - xStep), xStep + out, z end
            if math.abs(x - xUnder) < best then best, bx, bz = math.abs(x - xUnder), xUnder - out, z end
            if z1 < ROOM_HALF_Z - BODY_RADIUS and z1 - z < best then bx, bz = x, z1 + 0.001 end
            x, z = bx, bz
        end
    end
    return x, z
end

local function collide(self: Room)
    local r = BODY_RADIUS
    if self.feetY > 1.0 then
        self.camX = math.clamp(self.camX, ROOM_X0 + r, ROOM_X1 - r)
        self.camZ = math.clamp(self.camZ, -ROOM_HALF_Z + r, ROOM_HALF_Z - r)
        return -- up on the walkways: canStand keeps you on them
    end
    self.camX = math.clamp(self.camX, ROOM_X0 + r, ROOM_X1 - r)
    self.camZ = math.clamp(self.camZ, -ROOM_HALF_Z + r, ROOM_HALF_Z - r)
    if self.feetY <= STEP_UP then
        self.camX, self.camZ = pushOutOfStair(self.feetY, self.camX, self.camZ)
    end
    for _, b in WALL_BOXES do
        local x0, x1, z0, z1 = b.x0 - r, b.x1 + r, b.z0 - r, b.z1 + r
        if self.camX > x0 and self.camX < x1 and self.camZ > z0 and self.camZ < z1 then
            local dl, dr, db, df = self.camX - x0, x1 - self.camX, self.camZ - z0, z1 - self.camZ
            local m = math.min(dl, dr, db, df)
            if m == dl then self.camX = x0 elseif m == dr then self.camX = x1 elseif m == db then self.camZ = z0 else self.camZ = z1 end
        end
    end
    for _, b in Meta.colliders do
        local x0, x1, z0, z1 = b.x0 - r, b.x1 + r, b.z0 - r, b.z1 + r
        if self.camX > x0 and self.camX < x1 and self.camZ > z0 and self.camZ < z1 then
            local dl, dr, db, df = self.camX - x0, x1 - self.camX, self.camZ - z0, z1 - self.camZ
            local m = math.min(dl, dr, db, df)
            if m == dl then
                self.camX = x0
            elseif m == dr then
                self.camX = x1
            elseif m == db then
                self.camZ = z0
            else
                self.camZ = z1
            end
        end
    end
end

-- The alarm chime: a soft two-note clip with a pause, repeated while the alarm sounds; stops when silenced.
local function mixAlarm(self: Room)
    local source = self.alarmSource
    if source == nil then return end
    local text, silenced = Sim.alarm(self.ui.sim)
    local sounding = text ~= nil and not silenced and self.soundOn
    local now = Audio.time()
    if sounding then
        if self.alarmSound == nil or now > self.alarmNext + 0.5 then self.alarmNext = now end
        if now > self.alarmNext - 0.3 then
            local snd = Audio.playAtTime(source, self.alarmNext)
            if snd ~= nil then snd.volume = 0.2 end
            self.alarmSound = snd
            self.alarmNext += source.duration
        end
    elseif self.alarmSound ~= nil then
        (self.alarmSound :: AudioSound):stop()
        self.alarmSound = nil
    end
end

-- Talks to the page: sends finished games and exercises, reads saved progress.
local function linkPage(self: Room)
    local sim = self.ui.sim
    local sync = self.vmSync
    if sync ~= nil and sync.value ~= self.lastSync then
        self.lastSync = sync.value
        Sim.sync(sim, sync.value)
    end
    local out = self.vmReport
    local r = Sim.popReport(sim)
    if r ~= nil then
        -- Keep the last few lines, so the page catches up even if it misses a change.
        self.reportSeq += 1
        table.insert(self.reportLog, tostring(self.reportSeq) .. "|" .. r)
        if #self.reportLog > 8 then table.remove(self.reportLog, 1) end
        if out ~= nil then out.value = table.concat(self.reportLog, "\n") end
    end
end

-- Keeps each loop playing back to back on the audio clock, at a volume set by distance.
local function mixSound(self: Room, dt: number)
    for i, loop in self.loops do
        local source = loop.source
        local s = SOUNDS[i]
        if source ~= nil then
            local dx, dy, dz = self.camX - s.x, self.eyeY - s.y, self.camZ - s.z
            local target = if self.soundOn then s.level * math.exp(-math.sqrt(dx * dx + dy * dy + dz * dz) / s.falloff) else 0
            -- Muting fades out quickly; walking around blends slowly.
            loop.volume += (target - loop.volume) * (1 - math.exp(-dt * (if self.soundOn then 2.5 else 12)))
            local now = Audio.time()
            if loop.current == nil then
                loop.start = now
                loop.current = Audio.play(source)
            elseif now > loop.start + LOOP_LENGTH - 0.3 then
                loop.previous = loop.current
                loop.start += LOOP_LENGTH
                loop.current = Audio.playAtTime(source, loop.start)
            end
            local current = loop.current
            if current ~= nil then current.volume = loop.volume end
            local previous = loop.previous
            if previous ~= nil then previous.volume = loop.volume end
        end
    end
end

local function setTier(self: Room, tier: number)
    local t = TIERS[tier]
    self.tier = tier
    self.quality = t.res
    self.bloomOn = t.bloom and PERF.bloom
    self.ssaoOn = t.ssao and PERF.ssao
    local g = self.g
    if g ~= nil then
        g.samples = if t.msaa then g.maxSamples else 1
    end
    self.targetsDirty = true
    if PERF.profile then
        print(string.format("GOV tier %d: res %.2f bloom %s ssao %s msaa %s", tier, t.res, tostring(self.bloomOn), tostring(self.ssaoOn), tostring(t.msaa)))
    end
end

-- Holds 60 Hz: steps down the quality ladder when frames miss it, and back up
-- after a calm spell. A drop soon after a raise caps the ladder there, so it never oscillates.
local function govern(self: Room, seconds: number)
    if self.time < 3 or seconds > 0.25 then
        return
    end
    if seconds > GOV.MISS_FRAME then
        self.slowFrames += 1
    end
    self.slowTimer += seconds
    self.calmTimer += seconds
    if self.slowTimer < GOV.WINDOW then
        return
    end
    local misses = self.slowFrames
    self.slowFrames, self.slowTimer = 0, 0
    if misses >= GOV.MISS_LIMIT then
        self.calmTimer = 0
        if self.tier < #TIERS then
            local next = math.min(#TIERS, self.tier + (if misses > 25 then 2 else 1))
            if self.time - self.lastRaise < GOV.RAISE_GRACE then
                self.tierCap = math.max(self.tierCap, next)
            end
            setTier(self, next)
        end
    elseif misses > 0 then
        self.calmTimer = 0
    elseif self.calmTimer >= GOV.CALM_RAISE and self.tier > self.tierCap then
        self.calmTimer = 0
        self.lastRaise = self.time
        setTier(self, self.tier - 1)
    end
end

-- ---------------------------------------------------------------------------
-- Training: click to inspect, drag to look, pipe highlighting, valve operation
-- ---------------------------------------------------------------------------

local function cameraBasis(self: Room): (Vector, Vector, Vector)
    local cp = math.cos(self.pitch)
    local f = Vector.xyz(math.sin(self.yaw) * cp, math.sin(self.pitch), -math.cos(self.yaw) * cp)
    local r = Vector.xyz(math.cos(self.yaw), 0, math.sin(self.yaw))
    local u = Vector.xyz(r.y * f.z - r.z * f.y, r.z * f.x - r.x * f.z, r.x * f.y - r.y * f.x)
    return f, r, u
end

-- Nearest object under a layout point: its inspect id ("" for scenery), or nil for nothing.
local function pickAt(self: Room, px: number, py: number): string?
    local g = self.g
    if g == nil or self.size.x <= 0 then return nil end
    local f, r, u = cameraBasis(self)
    local th = math.tan(math.rad(FOV_DEGREES) / 2)
    local nx, ny = (px / self.size.x) * 2 - 1, 1 - (py / self.size.y) * 2
    local ax = nx * th * self.size.x / self.size.y
    local ay = ny * th
    local dx, dy, dz = f.x + r.x * ax + u.x * ay, f.y + r.y * ax + u.y * ay, f.z + r.z * ax + u.z * ay
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    dx, dy, dz = dx / len, dy / len, dz / len
    local ox, oy, oz = self.camX + self.swayX, self.eyeY, self.camZ + self.swayZ
    -- Boxes the ray enters, nearest first
    local hits: { { t: number, i: number } } = {}
    local leak = Sim.leak(self.ui.sim)
    for i, ob in Meta.objects do
        -- Training leaks exist only while their scenario shows them.
        if string.sub(ob.pick, 1, 5) == "leak:" and string.sub(ob.pick, 6, 7) ~= leak then continue end
        if ob.pick == "pass" then continue end -- walkway rails and grating: you click past them
        local t0, t1 = 0, 1e9
        local ok = true
        for k = 1, 3 do
            local o = if k == 1 then ox elseif k == 2 then oy else oz
            local d = if k == 1 then dx elseif k == 2 then dy else dz
            local lo, hi = ob.min[k] - 0.01, ob.max[k] + 0.01
            if math.abs(d) < 1e-9 then
                if o < lo or o > hi then ok = false; break end
            else
                local a, b = (lo - o) / d, (hi - o) / d
                if a > b then a, b = b, a end
                t0, t1 = math.max(t0, a), math.min(t1, b)
                if t0 > t1 then ok = false; break end
            end
        end
        if ok then table.insert(hits, { t = t0, i = i }) end
    end
    table.sort(hits, function(a: { t: number, i: number }, b: { t: number, i: number }): boolean return a.t < b.t end)
    local best, bestId = 1e9, nil
    local V, I = g.vdata, g.idata
    for _, h in hits do
        if h.t > best then break end
        local ob = Meta.objects[h.i]
        for tri = ob.first, ob.first + ob.count - 1 do
            local ia, ib, ic = buffer.readu32(I, tri * 12) * 24, buffer.readu32(I, tri * 12 + 4) * 24, buffer.readu32(I, tri * 12 + 8) * 24
            local axv, ayv, azv = buffer.readf32(V, ia), buffer.readf32(V, ia + 4), buffer.readf32(V, ia + 8)
            local e1x, e1y, e1z = buffer.readf32(V, ib) - axv, buffer.readf32(V, ib + 4) - ayv, buffer.readf32(V, ib + 8) - azv
            local e2x, e2y, e2z = buffer.readf32(V, ic) - axv, buffer.readf32(V, ic + 4) - ayv, buffer.readf32(V, ic + 8) - azv
            local px2, py2, pz2 = dy * e2z - dz * e2y, dz * e2x - dx * e2z, dx * e2y - dy * e2x
            local det = e1x * px2 + e1y * py2 + e1z * pz2
            if math.abs(det) > 1e-10 then
                local inv = 1 / det
                local sx, sy, sz = ox - axv, oy - ayv, oz - azv
                local uu = (sx * px2 + sy * py2 + sz * pz2) * inv
                if uu >= 0 and uu <= 1 then
                    local qx, qy, qz = sy * e1z - sz * e1y, sz * e1x - sx * e1z, sx * e1y - sy * e1x
                    local vv = (dx * qx + dy * qy + dz * qz) * inv
                    if vv >= 0 and uu + vv <= 1 then
                        local t = (e2x * qx + e2y * qy + e2z * qz) * inv
                        if t > 1e-3 and t < best then best, bestId = t, ob.pick end
                    end
                end
            end
        end
    end
    if bestId ~= nil and string.sub(bestId, 1, 5) == "leak:" then bestId = string.sub(bestId, 1, 7) end -- a falling drop is its leak
    return bestId
end

-- Animation slots that belong to an inspect id (its handwheels).
local function animSlots(id: string): { number }
    local slots = {}
    for i, a in Meta.anims do
        if a.pick == id then table.insert(slots, i) end
    end
    return slots
end

local function valveMoving(self: Room, id: string): boolean
    for _, i in animSlots(id) do
        if math.abs(self.ui.angle[i] - self.ui.angleTarget[i]) > 0.01 then return true end
    end
    return false
end

local function fmt(v: number, unit: string, digits: number?): string
    return string.format("%." .. tostring(digits or 1) .. "f %s", v, unit)
end

-- Simulated readings for the panel, by inspect id.
local function readings(self: Room, id: string): { UI.Reading }
    local s = self.telemetry
    local out: { UI.Reading } = {}
    local function add(label: string, value: string) table.insert(out, { label = label, value = value }) end
    local function kpa(v: number): string return string.format("%d kPa  (%d psi)", math.round(v), math.round(v * 0.145)) end
    local chillerN = tonumber(string.match(id, "^chiller:CH%-(%d)$") or string.match(id, "^panel:CH(%d)%-CP$") or "")
    if chillerN ~= nil then
        s = Art.chillerView(s, chillerN)
        add("Status", if s.load <= 0 then "STANDBY (ready to start)" else "RUNNING"); add("Load", string.format("%d %%", math.round(s.load * 100)))
        add("Leaving chilled water", fmt(s.lchw, "°F")); add("Entering chilled water", fmt(s.echw, "°F"))
        add("Entering condenser water", fmt(s.ecw, "°F")); add("Leaving condenser water", fmt(s.lcw, "°F"))
        add("Power", fmt(s.kw, "kW", 0))
    elseif string.sub(id, 1, 5) == "pump:" then
        local tag = string.sub(id, 6)
        local duty = tag == "CHWP-1" or tag == "CWP-1"
        add("Status", if duty then "RUNNING" else "STANDBY")
        if duty then
            local hz = if tag == "CHWP-1" then s.hz1 else s.hz2
            add("Drive speed", fmt(hz, "Hz")); add("Motor speed", string.format("%d rpm", math.round(hz * 29.4)))
            add("Flow", string.format("%d gpm", math.round(hz / 60 * (if tag == "CHWP-1" then 1200 else 1500))))
        end
        local face = if tag == "CHWP-1" then "CHW Pump 1 Gauge Face" elseif tag == "CHWP-2" then "CHW Pump 2 Gauge Face" elseif tag == "CWP-1" then "CW Pump 1 Gauge Face" else "CW Pump 2 Gauge Face"
        add("Suction pressure", kpa(Art.gaugeValue(tag .. " Suction Gauge Face", s)))
        add("Discharge pressure", if duty then kpa(Art.gaugeValue(face, s)) else kpa(Art.gaugeValue(tag .. " Suction Gauge Face", s)))
    elseif string.sub(id, 1, 6) == "valve:" then
        if id == "valve:CHW-BYP" then
            add("Position", string.format("%d %% open (modulating)", math.round(12 + 4 * math.sin(s.t * 0.2))))
        else
            add("Position", if self.ui.valves[id] == false then "CLOSED" else "OPEN")
        end
    elseif string.match(id, "^gauge:CH%d%-") ~= nil then
        local gn = tonumber(string.sub(id, 9, 9)) or 1
        local code = string.sub(id, 11)
        local cs = Art.chillerView(s, gn)
        local names: { [string]: string } = { CHWS = "Chilled Water Supply Gauge Faces", CHWR = "Chilled Water Return Gauge Faces", CWS = "Condenser Water Supply Gauge Faces", CWR = "Condenser Water Return Gauge Faces" }
        local temps = { CHWS = cs.lchw, CHWR = cs.echw, CWS = cs.ecw, CWR = cs.lcw }
        local prefix = if gn > 1 then string.format("CH-%d ", gn) else ""
        add("Pressure", kpa(Art.gaugeValue(prefix .. (names[code] or ""), cs)))
        add("Temperature", string.format("%.1f °F  (%.1f °C)", temps[code] or 0, ((temps[code] or 32) - 32) / 1.8))
    elseif string.sub(id, 1, 6) == "gauge:" then
        add("Pressure", kpa(Art.gaugeValue(string.sub(id, 7, -3) .. " Suction Gauge Face", s)))
    elseif id == "elec:VFD" then
        add("CHWP-1 drive", fmt(s.hz1, "Hz")); add("CHWP-2 drive", "STOPPED"); add("CWP-1 drive", fmt(s.hz2, "Hz")); add("CWP-2 drive", "STOPPED")
    elseif id == "monitor:RLM-1" then
        add("Refrigerant in air", string.format("%d ppm", math.round(s.ppm))); add("Alarm setpoint", "300 ppm"); add("Status", "NORMAL")
    elseif string.sub(id, 1, 5) == "pipe:" then
        local code = string.sub(id, 6)
        local temps = { CHWS = s.lchw, CHWR = s.echw, CWS = s.ecw, CWR = s.lcw }
        add("Water temperature", fmt(temps[code] or 0, "°F"))
    end
    Sim.readings(self.ui.sim, id, out)
    return out
end

local function panelState(self: Room, id: string): UI.PanelState
    local sim = self.ui.sim
    return {
        id = id, open = self.ui.valves[id] ~= false, moving = valveMoving(self, id), readings = readings(self, id),
        conceal = Sim.conceal(sim, id), extra = Sim.panelExtra(sim, id), knowledge = Sim.knowledge(sim),
    }
end

local function layoutPanel(self: Room)
    local id = self.ui.selected
    if id ~= nil then
        self.ui.panelH, self.ui.panelButtons = UI.paintPanel(nil, self.fonts, panelState(self, id))
    end
end

-- The scenario card's layout, so its buttons work before it has painted.
local function layoutCard(self: Room)
    local ui = self.ui
    if ui.sim.active then
        ui.cardH, ui.cardButtons = UI.paintCard(nil, self.fonts, Sim.card(ui.sim))
    end
end

-- Union bounds of each inspect id's pieces.
local pickBounds: { [string]: { min: { number }, max: { number } } }? = nil
local function boundsOf(id: string): { min: { number }, max: { number } }?
    if pickBounds == nil then
        local t = {}
        for _, ob in Meta.objects do
            local key = ob.pick
            if string.sub(key, 1, 5) == "leak:" then key = string.sub(key, 1, 7) end
            if key ~= "" then
                local b = t[key]
                if b == nil then
                    t[key] = { min = { ob.min[1], ob.min[2], ob.min[3] }, max = { ob.max[1], ob.max[2], ob.max[3] } }
                else
                    for k = 1, 3 do
                        b.min[k] = math.min(b.min[k], ob.min[k]); b.max[k] = math.max(b.max[k], ob.max[k])
                    end
                end
            end
        end
        pickBounds = t
    end
    return (pickBounds :: any)[id]
end

-- Close enough to count as "at" the equipment: within REACH metres of its box, on the floor plan.
local REACH = 3.5
local function isNear(self: Room, id: string): boolean
    local b = boundsOf(id)
    if b == nil then return true end
    if self.feetY > 1.0 and b.max[2] < self.feetY - 0.3 then return false end -- seen from a walkway: go down to it
    if b.min[2] > self.feetY + 3.0 then return false end -- overhead (the walkway vents): go up to it
    local dx = math.max(b.min[1] - self.camX, 0, self.camX - b.max[1])
    local dz = math.max(b.min[3] - self.camZ, 0, self.camZ - b.max[3])
    return dx * dx + dz * dz <= REACH * REACH
end

local function select(self: Room, id: string?)
    local ui = self.ui
    if id ~= nil and Training[id] == nil then id = nil end
    if ui.selected ~= id then
        ui.selected = id
        ui.panelDirty = true
        if id ~= nil then Sim.onSelect(ui.sim, id, isNear(self, id)) end
        layoutPanel(self)
    elseif id ~= nil then
        -- Clicking what's already open still counts toward the current step.
        Sim.onSelect(ui.sim, id, isNear(self, id))
    end
end

local function operateValve(self: Room, id: string)
    local ui = self.ui
    if valveMoving(self, id) then return end
    local open = ui.valves[id] ~= false
    ui.valves[id] = not open
    layoutPanel(self)
    -- Closing turns the handwheels clockwise (seen from the operator), opening back; three turns either way.
    for _, i in animSlots(id) do
        ui.angleTarget[i] += (if open then -1 else 1) * math.pi * 6
    end
    ui.panelDirty = true
end

-- Where the panel and toolbar sit (layout points) and their scale on narrow screens.
local function panelRect(self: Room): (number, number, number)
    local f = math.min(1, (self.size.x - 16) / UI.PANEL_W)
    local x = if self.size.x < 760 then 8 else self.size.x - UI.PANEL_W - 16
    return x, if self.size.x < 760 then 120 else 72, f
end

local function toolbarRect(self: Room): (number, number, number)
    local f = math.min(1, (self.size.x - 16) / UI.TOOLBAR_W)
    local w = UI.TOOLBAR_W * f
    local y = if self.size.x < 760 then 72 else self.size.y - UI.TOOLBAR_H * f - 16
    return (self.size.x - w) / 2, y, f
end

-- The scenario card: left, between the page's title box and its controls box
-- (results sit in the middle). It scales down to fit. Hidden on narrow screens
-- while the inspect panel is open, which then carries the scenario's buttons.
local function cardRect(self: Room): (number, number, number, boolean)
    local ui = self.ui
    if not ui.sim.active then return 0, 0, 0, false end
    local narrow = self.size.x < 760
    if narrow and ui.selected ~= nil then return 0, 0, 0, false end
    local h = math.max(ui.cardH, 1)
    if narrow then
        local _, ty, tf = toolbarRect(self)
        local y = ty + UI.TOOLBAR_H * tf + 10
        local f = math.min(1, (self.size.x - 16) / UI.CARD_W, (self.size.y - y - 150) / h)
        return 8, y, f, true
    end
    local _, ty = toolbarRect(self)
    if ui.sim.phase == "results" then
        local y = 92
        local f = math.min(1, (ty - 12 - y) / h)
        return (self.size.x - UI.CARD_W * f) / 2, y, f, true
    end
    local y = 124
    local f = math.min(1, (self.size.y - 150 - y) / h)
    return 16, y, f, true
end

local function bannerRect(self: Room): (number, number, number)
    local _, ty, tf = toolbarRect(self)
    local w = self.ui.bannerW * tf
    local y = if self.size.x < 760 then ty + UI.TOOLBAR_H * tf + 8 else ty - UI.BANNER_H * tf - 10
    return (self.size.x - w) / 2, y, tf
end

local function inRect(px: number, py: number, x: number, y: number, w: number, h: number): boolean
    return px >= x and px <= x + w and py >= y and py <= y + h
end

local function hitButtons(buttons: { UI.Button }, x0: number, y0: number, f: number, px: number, py: number): string?
    for _, b in buttons do
        if px >= x0 + b.x * f and px <= x0 + (b.x + b.w) * f and py >= y0 + b.y * f and py <= y0 + (b.y + b.h) * f then
            return b.action
        end
    end
    return nil
end

-- The mini game panel: centred, scaled down to fit small screens.
local function gameRect(self: Room): (number, number, number)
    local f = math.min(1, (self.size.x - 24) / Games.W, (self.size.y - 24) / Games.H)
    return (self.size.x - Games.W * f) / 2, (self.size.y - Games.H * f) / 2, f
end

-- A hit region of the open game under the pointer.
local function gameHit(self: Room, px: number, py: number): string?
    local game = Sim.game(self.ui.sim)
    if game == nil then return nil end
    self.ui.gameHits = Games.paint(nil, self.fonts, game) -- layout only: the state may have changed since the last frame
    local gx, gy, gf = gameRect(self)
    return hitButtons(self.ui.gameHits, gx, gy, gf, px, py)
end

local function click(self: Room, px: number, py: number)
    local ui = self.ui
    local game = Sim.game(ui.sim)
    if game ~= nil then
        local a = gameHit(self, px, py)
        if a == "close" then
            Sim.closeGame(ui.sim)
        elseif a == "finish" then
            Sim.finishGame(ui.sim)
        elseif a == "retry" then
            Sim.retryGame(ui.sim)
        elseif a == "skip" then
            Sim.skipGame(ui.sim)
        elseif a == "slider" then
            local gx, _, gf = gameRect(self)
            Games.drag(game, (px - gx) / gf)
        elseif a ~= nil then
            Games.action(game, a)
        end
        layoutCard(self)
        return
    end
    local tx, ty, tf = toolbarRect(self)
    local action = hitButtons(ui.toolbarButtons, tx, ty, tf, px, py)
    if action == "sim" then
        if ui.sim.active then Sim.stop(ui.sim) else Sim.begin(ui.sim) end
        select(self, nil)
        ui.toolbarDirty = true
        layoutCard(self)
        return
    elseif action ~= nil then
        ui.highlight = tonumber(string.sub(action, 3)) or 0
        ui.toolbarDirty = true
        return
    end
    local cx, cy, cf, cardOn = cardRect(self)
    if cardOn and inRect(px, py, cx, cy, UI.CARD_W * cf, ui.cardH * cf) then
        local a = hitButtons(ui.cardButtons, cx, cy, cf, px, py)
        if a ~= nil then
            local phase, version = ui.sim.phase, ui.sim.step
            Sim.cardAction(ui.sim, a)
            if Sim.game(ui.sim) ~= nil then select(self, nil) end
            -- A new exercise (or none) starts with the panel closed.
            if ui.sim.phase ~= phase or a == "retry" or (string.sub(a, 1, 6) == "start:") or version ~= ui.sim.step and ui.sim.phase ~= "play" then select(self, nil) end
            if not ui.sim.active then ui.toolbarDirty = true end
            layoutCard(self)
        end
        return
    end
    if ui.selected ~= nil then
        local x, y, f = panelRect(self)
        if px >= x and px <= x + UI.PANEL_W * f and py >= y and py <= y + ui.panelH * f then
            local a = hitButtons(ui.panelButtons, x, y, f, px, py)
            if a == "close" then select(self, nil)
            elseif a == "toggle" then operateValve(self, ui.selected :: string)
            elseif a ~= nil then
                Sim.panelAction(ui.sim, ui.selected :: string, a)
                layoutPanel(self)
                layoutCard(self)
            end
            return
        end
    end
    select(self, pickAt(self, px, py))
    -- Clicking a game step's target opens the game over everything: close the panel.
    if Sim.game(ui.sim) ~= nil then select(self, nil); layoutCard(self) end
end

function pointerDown(self: Room, event: PointerEvent)
    local p = event.position
    self.ui.down = { x = p.x, y = p.y, lastX = p.x, lastY = p.y, moved = false }
    self.ui.pointer = p
    local game = Sim.game(self.ui.sim)
    local hit = if game ~= nil then gameHit(self, p.x, p.y) else nil
    if game ~= nil and (hit == "slider" or hit == "wheel") then
        self.ui.gameDrag = true
        local gx, gy, gf = gameRect(self)
        Games.dragStart(game, (p.x - gx) / gf, (p.y - gy) / gf)
        if hit == "slider" then Games.drag(game, (p.x - gx) / gf) end
    end
end

function pointerMove(self: Room, event: PointerEvent)
    local p = event.position
    local ui = self.ui
    ui.pointer = p
    local d = ui.down
    local game = Sim.game(ui.sim)
    if game ~= nil then
        -- The game owns the pointer: drag its slider, never turn the camera.
        if ui.gameDrag then
            local gx, gy, gf = gameRect(self)
            Games.drag(game, (p.x - gx) / gf, (p.y - gy) / gf)
        end
        if d ~= nil and math.abs(p.x - d.x) + math.abs(p.y - d.y) > 6 then d.moved = true end
        return
    end
    if d ~= nil then
        if math.abs(p.x - d.x) + math.abs(p.y - d.y) > 6 then d.moved = true end
        if d.moved then
            self.yaw += (p.x - d.lastX) * 0.0045
            self.pitch = math.clamp(self.pitch - (p.y - d.lastY) * 0.0045, -1.45, 1.45)
        end
        d.lastX, d.lastY = p.x, p.y
    end
end

function pointerUp(self: Room, event: PointerEvent)
    local d = self.ui.down
    self.ui.down = nil
    if self.ui.gameDrag then
        self.ui.gameDrag = false
        local game = Sim.game(self.ui.sim)
        if game ~= nil then Games.dragEnd(game) end
        return
    end
    if d ~= nil and not d.moved then
        click(self, event.position.x, event.position.y)
    end
end

function pointerExit(self: Room, event: PointerEvent)
    self.ui.down = nil
    self.ui.pointer = nil
    if self.ui.hover ~= nil then self.ui.hover = nil; self.ui.hintDirty = true end
end

-- Per frame, while a scenario runs: its valve line-up, its leak and repaints.
local LEAK_FLOOR: { [string]: number } = { L1 = 0.262, L2 = 0.006, L3 = 0.262 } -- where each leak's drops land
local DROP_PERIOD = 0.9 -- seconds between drops
local HIDDEN = -50 -- metres: parked below the floor

local function stepScenario(self: Room, dt: number)
    local ui = self.ui
    local sim = ui.sim
    -- A new run starts from the normal line-up (all valves open), then sets its own.
    if sim.run ~= ui.simRun then
        ui.simRun = sim.run
        for id in ui.valves do ui.valves[id] = nil end
        for i, a in Meta.anims do
            if string.sub(a.pick, 1, 6) == "valve:" then ui.angle[i] = 0; ui.angleTarget[i] = 0 end
        end
        local forced = Sim.valves(sim)
        if forced ~= nil then
            for id, open in forced do
                ui.valves[id] = open
                for _, i in animSlots(id) do
                    if not open then ui.angle[i] = -math.pi * 6; ui.angleTarget[i] = -math.pi * 6 end
                end
            end
        end
        ui.panelDirty = true
    end
    local leak = Sim.leak(sim)
    for i, a in Meta.anims do
        if string.sub(a.pick, 1, 5) == "leak:" then
            local k = string.sub(a.pick, 6, 7)
            local lift = HIDDEN
            if k == leak then
                if string.sub(a.pick, 8) == ":drip" then
                    local h = a.pivot[2] - 0.03 - (LEAK_FLOOR[k] or 0)
                    local fall = math.sqrt(2 * h / 9.81)
                    local t = (self.time + i * 0.37) % DROP_PERIOD
                    lift = if t < fall then -0.5 * 9.81 * t * t else HIDDEN
                else
                    lift = 0
                end
            end
            ui.lift[i] = lift
        end
    end
    -- Toasts: one at a time; a queue shortens each.
    local toast = ui.toast
    if toast ~= nil then
        toast.t += dt
        if toast.t >= toast.life then ui.toast = nil end
    end
    if ui.toast == nil then
        local nextToast = Sim.popToast(sim)
        if nextToast ~= nil then
            ui.toast = { text = nextToast.text, tone = nextToast.tone, points = nextToast.points, t = 0, life = if #sim.toasts > 0 then 1.2 else 2.2 }
            ui.toastDirty = true
        end
    end
    -- Confetti for a good result.
    if sim.phase ~= ui.lastPhase then
        if sim.phase == "results" and ui.lastPhase == "play" and Sim.stars(sim) >= 2 then
            local colors = { Color.rgb(64, 200, 236), Color.rgb(246, 176, 46), Color.rgb(84, 214, 120), Color.rgb(232, 96, 82), Color.rgb(240, 240, 250) }
            for i = 1, 110 do
                table.insert(ui.confetti, {
                    x = self.size.x * (0.2 + 0.6 * math.random()), y = -10 - 120 * math.random(),
                    vx = (math.random() - 0.5) * 160, vy = 60 + 140 * math.random(),
                    a = math.random() * math.pi, va = (math.random() - 0.5) * 10,
                    w = 5 + 5 * math.random(), h = 3 + 3 * math.random(), color = colors[(i % #colors) + 1],
                })
            end
        end
        ui.lastPhase = sim.phase
    end
    if #ui.confetti > 0 then
        local keep = {}
        for _, c in ui.confetti do
            c.vy += 220 * dt
            c.vx *= 1 - 0.8 * dt
            c.x += c.vx * dt + math.sin(c.a * 2) * 20 * dt
            c.y += c.vy * dt
            c.a += c.va * dt
            if c.y < self.size.y + 20 then table.insert(keep, c) end
        end
        ui.confetti = keep
    end
    if sim.version ~= ui.simVersion then
        ui.simVersion = sim.version
        ui.cardDirty, ui.panelDirty, ui.hintDirty, ui.bannerDirty = true, true, true, true
        layoutCard(self)
        layoutPanel(self)
    end
end

-- Per frame: turn handwheels toward their targets, refresh hover and live readings.
-- The travel clock: once per step, allow the walk to the nearest target (at walking pace,
-- with the stair climb for targets up on the walkway); then tick it.
local function stepReach(self: Room, dt: number)
    local sim = self.ui.sim
    local state, _, limit = Sim.reachClock(sim)
    if state ~= "running" then return end
    if limit == nil then
        local targets = Sim.stepTargets(sim)
        if targets == nil then return end
        local best = 1e9
        for _, id in targets do
            local b = boundsOf(id)
            if b ~= nil then
                local tx, tz = math.clamp(self.camX, b.min[1], b.max[1]), math.clamp(self.camZ, b.min[3], b.max[3])
                local d = math.abs(tx - self.camX) + math.abs(tz - self.camZ) -- around equipment, not through it
                local high = b.min[2] > self.feetY + 3.0
                local low = self.feetY > 1.0 and b.max[2] < self.feetY - 0.3
                if high or low then
                    -- Via the stair: its foot (x 35.8) and top (x 26.8) on the south wall, plus 9 m of steps.
                    local sx, sz = if high then 36.3 else 26.8, 6.2
                    local ex, ez = if high then 26.8 else 36.3, 6.2
                    d = math.abs(sx - self.camX) + math.abs(sz - self.camZ) + 11 + math.abs(tx - ex) + math.abs(tz - ez)
                end
                best = math.min(best, d)
            end
        end
        if best < 1e9 then Sim.setReachLimit(sim, best / WALK_SPEED) end
        return
    end
    Sim.tickReach(sim, dt)
end

local function stepTraining(self: Room, dt: number)
    local ui = self.ui
    for i = 1, #Meta.anims do
        local a, t = ui.angle[i], ui.angleTarget[i]
        if a ~= t then
            local step = math.pi * 2 * 1.4 * dt
            ui.angle[i] = if math.abs(t - a) <= step then t else a + step * math.sign(t - a)
            if ui.angle[i] == t then ui.panelDirty = true end
        end
    end
    stepReach(self, dt)
    ui.hoverTimer -= dt
    if SHOW_HOVER_HINT and ui.hoverTimer <= 0 and ui.down == nil then
        ui.hoverTimer = 0.12
        local p = ui.pointer
        local overUi = false
        if p ~= nil then
            local tx, ty, tf = toolbarRect(self)
            overUi = p.x >= tx and p.x <= tx + UI.TOOLBAR_W * tf and p.y >= ty and p.y <= ty + UI.TOOLBAR_H * tf
            local cx, cy, cf, cardOn = cardRect(self)
            overUi = overUi or (cardOn and inRect(p.x, p.y, cx, cy, UI.CARD_W * cf, ui.cardH * cf))
            if ui.selected ~= nil then
                local x, y, f = panelRect(self)
                overUi = overUi or (p.x >= x and p.x <= x + UI.PANEL_W * f and p.y >= y and p.y <= y + ui.panelH * f)
            end
        end
        local id: string? = if p ~= nil and not overUi then pickAt(self, p.x, p.y) else nil
        if id ~= nil and Training[id :: string] == nil then id = nil end
        if id ~= ui.hover then ui.hover = id; ui.hintDirty = true end
    end
    if ui.selected ~= nil then
        ui.liveTimer -= dt
        if ui.liveTimer <= 0 then ui.liveTimer = 0.5; ui.panelDirty = true end
    end
    stepScenario(self, dt)
end

local function newUi(): any
    local angle, target = {}, {}
    local lift = {}
    for i, a in Meta.anims do
        angle[i] = 0; target[i] = 0
        lift[i] = if string.sub(a.pick, 1, 5) == "leak:" then -50 else 0 -- leaks start hidden
    end
    return {
        selected = nil, hover = nil, pointer = nil, down = nil,
        highlight = 0, valves = {}, angle = angle, angleTarget = target,
        panelDirty = true, toolbarDirty = true, hintDirty = true,
        panelButtons = {}, toolbarButtons = UI.toolbarButtons(), panelH = 0, hintW = 0,
        hoverTimer = 0, liveTimer = 0,
        lift = lift, sim = Sim.new(), simRun = nil, simVersion = -1,
        cardDirty = true, cardH = 0, cardButtons = {}, bannerDirty = true, bannerW = UI.BANNER_W,
        paintedScale = {},
        toast = nil, toastDirty = false, toastW = 0, tagText = "", tagW = 0, confetti = {}, lastPhase = "menu",
        gameHits = {}, gameDrag = false,
    }
end


-- ---------------------------------------------------------------------------
-- Guides: markers over the scenario's targets, a search zone on the floor,
-- an arrow at the screen's edge when the target is out of view.
-- ---------------------------------------------------------------------------

local ACCENT_C = Color.rgb(70, 235, 100) -- target pins match the green glow
local AMBER_C = Color.rgb(246, 176, 46)
local RED_C = Color.rgb(255, 60, 50) -- alarm switch pins match its red glow
local GREEN_C = Color.rgb(84, 214, 120)
local DARK_C = Color.rgb(12, 16, 22)

-- A world point in layout points: x, y, depth along the view (negative: behind),
-- and the camera-space x, y for pointing at it from the screen's edge.
local function project(self: Room, wx: number, wy: number, wz: number): (number, number, number, number, number)
    local f, r, u = cameraBasis(self)
    local dx, dy, dz = wx - self.camX - self.swayX, wy - self.eyeY, wz - self.camZ - self.swayZ
    local z = dx * f.x + dy * f.y + dz * f.z
    local cx = dx * r.x + dy * r.y + dz * r.z
    local cy = dx * u.x + dy * u.y + dz * u.z
    local th = math.tan(math.rad(FOV_DEGREES) / 2)
    local aspect = self.size.x / math.max(self.size.y, 1)
    if z <= 0.05 then return 0, 0, z, cx, cy end
    local nx, ny = cx / (z * th * aspect), cy / (z * th)
    return (nx + 1) / 2 * self.size.x, (1 - ny) / 2 * self.size.y, z, cx, cy
end

local function circlePath(cx: number, cy: number, rad: number): Path
    local k = rad * 0.5523
    local p = Path.new()
    p:moveTo(Vector.xy(cx + rad, cy))
    p:cubicTo(Vector.xy(cx + rad, cy + k), Vector.xy(cx + k, cy + rad), Vector.xy(cx, cy + rad))
    p:cubicTo(Vector.xy(cx - k, cy + rad), Vector.xy(cx - rad, cy + k), Vector.xy(cx - rad, cy))
    p:cubicTo(Vector.xy(cx - rad, cy - k), Vector.xy(cx - k, cy - rad), Vector.xy(cx, cy - rad))
    p:cubicTo(Vector.xy(cx + k, cy - rad), Vector.xy(cx + rad, cy - k), Vector.xy(cx + rad, cy))
    p:close()
    return p
end

-- A map pin whose tip sits on (x, y).
local function drawPin(r: Renderer, x: number, y: number, color: Color, t: number)
    local pulse = (t * 0.9) % 1
    r:drawPath(circlePath(x, y, 6 + 22 * pulse), Paint.with({ style = "stroke", thickness = 2.5, color = Color.rgba(255, 255, 255, math.floor(180 * (1 - pulse))) }))
    local bob = math.abs(math.sin(t * 3.2)) * 9
    local hy = y - 30 - bob
    local p = Path.new()
    p:moveTo(Vector.xy(x - 9, hy + 6)); p:lineTo(Vector.xy(x, y - 4 - bob)); p:lineTo(Vector.xy(x + 9, hy + 6)); p:close()
    r:drawPath(p, Paint.with({ color = color }))
    r:drawPath(circlePath(x, hy, 13), Paint.with({ color = color }))
    r:drawPath(circlePath(x, hy, 13), Paint.with({ style = "stroke", thickness = 2, color = Color.rgba(255, 255, 255, 220) }))
    r:drawPath(circlePath(x, hy, 4.5), Paint.with({ color = DARK_C }))
end

local function drawCheckPin(r: Renderer, x: number, y: number)
    r:drawPath(circlePath(x, y - 14, 10), Paint.with({ color = GREEN_C }))
    local p = Path.new()
    p:moveTo(Vector.xy(x - 4.5, y - 14)); p:lineTo(Vector.xy(x - 1, y - 10.5)); p:lineTo(Vector.xy(x + 5, y - 17.5))
    r:drawPath(p, Paint.with({ style = "stroke", thickness = 2.4, color = DARK_C, cap = "round", join = "round" }))
end

-- An arrow on the screen's edge, pointing along (dx, dy) in screen space.
local function drawEdgeArrow(self: Room, r: Renderer, dx: number, dy: number, color: Color, t: number): (number, number)
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-6 then dx, dy, len = 1, 0, 1 end
    dx, dy = dx / len, dy / len
    -- Kept in the clear view: right of the scenario card, left of the inspect
    -- panel, above the toolbar.
    local left, right, top, bottom = 50, self.size.x - 50, 100, self.size.y - 130
    local ccx, _, ccf, cardOn = cardRect(self)
    if cardOn and self.size.x >= 760 then left = ccx + UI.CARD_W * ccf + 40 end
    if self.ui.selected ~= nil and self.size.x >= 760 then
        local px = panelRect(self)
        right = px - 40
    end
    if right - left < 120 then left, right = 50, self.size.x - 50 end
    local cx, cy = (left + right) / 2, self.size.y / 2
    local hw, hh = (right - left) / 2, math.max(40, (bottom - top) / 2)
    local k = math.min(hw / math.max(math.abs(dx), 1e-6), hh / math.max(math.abs(dy), 1e-6))
    local push = math.sin(t * 5) * 5 - 6
    local x, y = cx + dx * (k + push), cy + dy * (k + push)
    local px, py = -dy, dx
    local p = Path.new()
    p:moveTo(Vector.xy(x + dx * 18, y + dy * 18))
    p:lineTo(Vector.xy(x - dx * 10 + px * 15, y - dy * 10 + py * 15))
    p:lineTo(Vector.xy(x - dx * 3, y - dy * 3))
    p:lineTo(Vector.xy(x - dx * 10 - px * 15, y - dy * 10 - py * 15))
    p:close()
    r:drawPath(circlePath(x, y, 26), Paint.with({ color = Color.rgba(12, 16, 22, 190) }))
    r:drawPath(p, Paint.with({ color = color }))
    -- Where the tag goes: beside the arrow, toward the middle of the screen.
    local tw = self.ui.tagW
    if math.abs(dx) >= math.abs(dy) then
        return if dx < 0 then x + 34 else x - 34 - tw, y - UI.TAG_H / 2
    end
    return x - tw / 2, if dy < 0 then y + 34 else y - 34 - UI.TAG_H
end

local function blitAt(self: Room, r: Renderer, canvas: Canvas, x: number, y: number, scale: number?, opacity: number?)
    local us = math.max(1, self.scale)
    local k = (scale or 1) / us
    r:save()
    r:transform(Mat2D.withScaleAndTranslation(k, k, math.round(x * us) / us, math.round(y * us) / us))
    r:drawImage(canvas.image, ImageSampler("clamp", "clamp", if scale == nil then "nearest" else "bilinear"), "srcOver", opacity or 1)
    r:restore()
end

-- The tag over the main marker: repainted only when its text changes.
local function setTag(self: Room, text: string, zone: boolean, red: boolean?)
    local ui = self.ui
    local key = if red then "!" .. text else text
    if ui.tagText == key then return end
    ui.tagText = key
    local us = math.max(1, self.scale)
    local fr = self.g.tagCanvas:beginFrame({ clearColor = 0x00000000 })
    fr:save(); fr:transform(Mat2D.withScale(us, us))
    ui.tagW = UI.paintTag(fr, self.fonts, text, zone, red)
    fr:restore(); self.g.tagCanvas:endFrame()
end

local function shortName(id: string): string
    local e: any = Training[id]
    if e ~= nil and e.short ~= nil then return e.short end
    local name = if e ~= nil then e.title else id
    if #name <= 26 then return name end
    return string.match(name, "^(%u+%-%d+)") or name
end

-- A search zone's centre: offset from its target so the middle of the ring isn't the answer.
local function zoneCentre(m: any): (number?, number?)
    local b = boundsOf(m.zone)
    if b == nil then return nil, nil end
    local h = 0
    for i = 1, #m.zone do h = (h * 31 + string.byte(m.zone, i)) % 9973 end
    local ang = h % 360 * math.pi / 180
    local rad = m.zoneRadius
    return (b.min[1] + b.max[1]) / 2 + math.cos(ang) * rad * 0.45, (b.min[3] + b.max[3]) / 2 + math.sin(ang) * rad * 0.45
end

-- Inside a leak's search ring, the puddle shimmers blue so it reads as water.
local function leakShimmer(self: Room, m: any): string?
    if m == nil or m.zone == nil or string.sub(m.zone, 1, 5) ~= "leak:" then return nil end
    local zx, zz = zoneCentre(m)
    if zx == nil or zz == nil then return nil end
    local dx, dz = self.camX - zx, self.camZ - zz
    if math.sqrt(dx * dx + dz * dz) < m.zoneRadius then return m.zone end
    return nil
end

local function drawGuides(self: Room, r: Renderer)
    local sim = self.ui.sim
    local m = Sim.markers(sim)
    if m == nil then return end
    local t = self.time
    -- Search zone: a pulsing ring on the floor, offset so its centre isn't the answer.
    if m.zone ~= nil then
        local zx, zz = zoneCentre(m)
        if zx == nil or zz == nil then return end
        local rad = m.zoneRadius
        local pulse = 0.5 + 0.5 * math.sin(t * 2.4)
        for ring = 1, 2 do
            local rr = if ring == 1 then rad else rad * (0.35 + 0.65 * ((t * 0.5) % 1))
            local p = Path.new()
            local started = false
            for i = 0, 48 do
                local a = i / 48 * math.pi * 2
                local x, y, z = project(self, zx + math.cos(a) * rr, 0.03, zz + math.sin(a) * rr)
                if z > 0.3 then
                    if started then p:lineTo(Vector.xy(x, y)) else p:moveTo(Vector.xy(x, y)); started = true end
                else
                    started = false
                end
            end
            local alpha = if ring == 1 then math.floor(150 + 90 * pulse) else math.floor(160 * (1 - (t * 0.5) % 1))
            r:drawPath(p, Paint.with({ style = "stroke", thickness = if ring == 1 then 4 else 2.5, color = Color.rgba(246, 176, 46, alpha), join = "round" }))
        end
        local dx, dz = self.camX - zx, self.camZ - zz
        local dist = math.sqrt(dx * dx + dz * dz)
        local inside = dist < rad
        local lookFor = if string.sub(m.zone, 1, 5) == "leak:" then "You're in the zone: look down for water" else "You're in the zone: look around"
        setTag(self, if inside then lookFor else string.format("Search here · %d m", math.round(dist)), true)
        local sx, sy, z, cx, cy = project(self, zx, 1.3, zz)
        local onScreen = z > 0.05 and sx > 30 and sx < self.size.x - 30 and sy > 30 and sy < self.size.y - 30
        if inside then
            blitAt(self, r, self.g.tagCanvas, (self.size.x - self.ui.tagW) / 2, self.size.y * 0.5 + 40)
        elseif onScreen then
            drawPin(r, sx, sy, AMBER_C, t)
            blitAt(self, r, self.g.tagCanvas, sx - self.ui.tagW / 2, sy - 82)
        else
            local ex, ey = drawEdgeArrow(self, r, cx, -cy, AMBER_C, t)
            blitAt(self, r, self.g.tagCanvas, ex, ey)
        end
        return
    end
    -- Exact targets: pins on each; the nearest one still to do carries the tag.
    local pinC = if m.red then RED_C else ACCENT_C
    local nearest, nearestD = nil, 1e9
    for _, id in m.targets do
        local b = boundsOf(id)
        if b ~= nil and not m.done[id] then
            local ex = math.max(b.min[1] - self.camX, 0, self.camX - b.max[1])
            local ez = math.max(b.min[3] - self.camZ, 0, self.camZ - b.max[3])
            local d = math.sqrt(ex * ex + ez * ez)
            if d < nearestD then nearest, nearestD = id, d end
        end
    end
    for _, id in m.targets do
        local b = boundsOf(id)
        if b ~= nil then
            local x, y, z = project(self, (b.min[1] + b.max[1]) / 2, math.min(b.max[2], b.min[2] + 1.4) + 0.12, (b.min[3] + b.max[3]) / 2)
            if z > 0.05 then
                if m.done[id] then drawCheckPin(r, x, y) elseif id ~= nearest then drawPin(r, x, y, pinC, t + 0.4) end
            end
        end
    end
    if nearest ~= nil then
        local b = boundsOf(nearest) :: any
        local nb = boundsOf(nearest) :: any
        local up = nb.min[2] > self.feetY + 3.0
        local label = if up then shortName(nearest) .. " · go up to the walkway" elseif nearestD <= REACH then shortName(nearest) .. " · click it" else string.format("%s · %d m", shortName(nearest), math.round(nearestD))
        local rs, rt, rl = Sim.reachClock(self.ui.sim)
        local hurry = false
        if rs == "running" and rl ~= nil then
            local left = math.ceil((rl :: number) - rt)
            label ..= if left > 0 then string.format(" · %d:%02d", left // 60, left % 60) else " · LATE"
            hurry = left <= 5
        end
        setTag(self, label, false, m.red or hurry)
        local sx, sy, z, cx, cy = project(self, (b.min[1] + b.max[1]) / 2, math.min(b.max[2], b.min[2] + 1.4) + 0.12, (b.min[3] + b.max[3]) / 2)
        local onScreen = z > 0.05 and sx > 30 and sx < self.size.x - 30 and sy > 60 and sy < self.size.y - 30
        if onScreen then
            drawPin(r, sx, sy, pinC, t)
            blitAt(self, r, self.g.tagCanvas, sx - self.ui.tagW / 2, sy - 82)
        else
            local ex, ey = drawEdgeArrow(self, r, if z > 0.05 then sx - self.size.x / 2 else cx, if z > 0.05 then sy - self.size.y / 2 else -cy, pinC, t)
            blitAt(self, r, self.g.tagCanvas, ex, ey)
        end
    end
end

-- Toasts and confetti, over everything.
-- The open mini game: the room dims behind it; its panel repaints every frame (it animates).
local function drawGame(self: Room, r: Renderer)
    local game = Sim.game(self.ui.sim)
    if game == nil then return end
    local p = Path.new()
    p:moveTo(Vector.xy(0, 0)); p:lineTo(Vector.xy(self.size.x, 0)); p:lineTo(Vector.xy(self.size.x, self.size.y)); p:lineTo(Vector.xy(0, self.size.y)); p:close()
    r:drawPath(p, Paint.with({ color = Color.rgba(6, 10, 14, 170) }))
    local us = math.max(1, self.scale)
    local gx, gy, gf = gameRect(self)
    local canvas = self.g.gameCanvas
    local fr = canvas:beginFrame({ clearColor = 0x00000000 })
    fr:save(); fr:transform(Mat2D.withScale(us * gf, us * gf))
    self.ui.gameHits = Games.paint(fr, self.fonts, game)
    fr:restore(); canvas:endFrame()
    r:save()
    r:transform(Mat2D.withScaleAndTranslation(1 / us, 1 / us, math.round(gx * us) / us, math.round(gy * us) / us))
    r:drawImage(canvas.image, ImageSampler("clamp", "clamp", "nearest"), "srcOver", 1)
    r:restore()
end

local function drawFx(self: Room, r: Renderer)
    local ui = self.ui
    local toast = ui.toast
    if toast ~= nil then
        if ui.toastDirty then
            local us = math.max(1, self.scale)
            local fr = self.g.toastCanvas:beginFrame({ clearColor = 0x00000000 })
            fr:save(); fr:transform(Mat2D.withScale(us, us))
            ui.toastW = UI.paintToast(fr, self.fonts, toast.text, toast.tone, toast.points)
            fr:restore(); self.g.toastCanvas:endFrame()
            ui.toastDirty = false
        end
        local tt, life = toast.t, toast.life
        -- Pops in with a little overshoot, then fades away.
        local s = if tt < 0.18 then 0.7 + 0.42 * (tt / 0.18) elseif tt < 0.3 then 1.12 - 0.12 * ((tt - 0.18) / 0.12) else 1
        local a = if tt > life - 0.35 then math.max(0, (life - tt) / 0.35) else math.min(1, tt / 0.1)
        local w, h = ui.toastW * s, UI.TOAST_H * s
        local y = 22 - (if tt > life - 0.35 then (tt - (life - 0.35)) * 40 else 0)
        blitAt(self, r, self.g.toastCanvas, (self.size.x - w) / 2, y + (UI.TOAST_H - h) / 2, if s == 1 then nil else s, a)
    end
    for _, c in ui.confetti do
        local ca, sa = math.cos(c.a), math.sin(c.a)
        local hw, hh = c.w / 2, c.h / 2 * math.abs(math.cos(c.a * 1.7))
        local p = Path.new()
        p:moveTo(Vector.xy(c.x - ca * hw + sa * hh, c.y - sa * hw - ca * hh))
        p:lineTo(Vector.xy(c.x + ca * hw + sa * hh, c.y + sa * hw - ca * hh))
        p:lineTo(Vector.xy(c.x + ca * hw - sa * hh, c.y + sa * hw + ca * hh))
        p:lineTo(Vector.xy(c.x - ca * hw - sa * hh, c.y - sa * hw + ca * hh))
        p:close()
        r:drawPath(p, Paint.with({ color = c.color }))
    end
end

-- Paints whichever UI canvases changed, then composites them over the 3D view.
-- Each canvas is painted at its on-screen size in device pixels (layout scale f
-- times device scale) and drawn 1:1 on a whole device pixel, so text is never
-- resampled.
local function drawUi(self: Room, renderer: Renderer)
    local g, ui = self.g, self.ui
    local us = math.max(1, self.scale)
    local sim = ui.sim
    local alarm, acked = Sim.alarm(sim)
    local tx, ty, tf = toolbarRect(self)
    local cx, cy, cf, cardOn = cardRect(self)
    local bx, by, bf = 0, 0, 1
    if alarm ~= nil then bx, by, bf = bannerRect(self) end
    local px, py, pf = 0, 0, 1
    if ui.selected ~= nil then px, py, pf = panelRect(self) end

    -- A canvas painted at another layout scale is repainted at this one.
    local painted = ui.paintedScale
    local function stale(key: string, f: number): boolean
        if math.abs((painted[key] or -1) - f) > 1e-4 then
            painted[key] = f
            return true
        end
        return false
    end
    if stale("toolbar", tf) then ui.toolbarDirty = true end
    if stale("panel", pf) then ui.panelDirty = true end
    if cardOn and stale("card", cf) then ui.cardDirty = true end
    if stale("banner", bf) then ui.bannerDirty = true end

    local function paint(canvas: Canvas, f: number, body: (Renderer) -> ())
        local fr = canvas:beginFrame({ clearColor = 0x00000000 })
        fr:save(); fr:transform(Mat2D.withScale(us * f, us * f))
        body(fr)
        fr:restore(); canvas:endFrame()
    end
    if ui.toolbarDirty then
        paint(g.toolbarCanvas, tf, function(fr) ui.toolbarButtons = UI.paintToolbar(fr, self.fonts, ui.highlight, sim.active) end)
        ui.toolbarDirty = false
    end
    if ui.panelDirty and ui.selected ~= nil then
        local id = ui.selected
        paint(g.panelCanvas, pf, function(fr) ui.panelH, ui.panelButtons = UI.paintPanel(fr, self.fonts, panelState(self, id)) end)
        ui.panelDirty = false
    end
    if ui.hintDirty and ui.hover ~= nil then
        paint(g.hintCanvas, 1, function(fr) ui.hintW = UI.paintHint(fr, self.fonts, ui.hover, Sim.conceal(sim, ui.hover)) end)
        ui.hintDirty = false
    end
    if ui.cardDirty and sim.active then
        paint(g.cardCanvas, cf, function(fr) ui.cardH, ui.cardButtons = UI.paintCard(fr, self.fonts, Sim.card(sim)) end)
        ui.cardDirty = false
    end
    if ui.bannerDirty and alarm ~= nil then
        paint(g.bannerCanvas, bf, function(fr) ui.bannerW = UI.paintBanner(fr, self.fonts, alarm, acked) end)
        ui.bannerDirty = false
    end

    local sampler = ImageSampler("clamp", "clamp", "nearest")
    local function blit(canvas: Canvas, x: number, y: number, opacity: number?)
        renderer:save()
        renderer:transform(Mat2D.withScaleAndTranslation(1 / us, 1 / us, math.round(x * us) / us, math.round(y * us) / us))
        renderer:drawImage(canvas.image, sampler, "srcOver", opacity or 1)
        renderer:restore()
    end
    if alarm ~= nil then
        -- An unacknowledged alarm pulses.
        blit(g.bannerCanvas, bx, by, if acked then 0.92 else 0.72 + 0.28 * math.abs(math.sin(self.time * 3.2)))
    end
    if cardOn then blit(g.cardCanvas, cx, cy) end
    blit(g.toolbarCanvas, tx, ty)
    if ui.selected ~= nil then blit(g.panelCanvas, px, py) end
    if ui.hover ~= nil and ui.hover ~= ui.selected and ui.pointer ~= nil then
        local p = ui.pointer
        blit(g.hintCanvas, math.clamp(p.x - ui.hintW / 2, 8, self.size.x - ui.hintW - 8), p.y + 22)
    end
end

function advance(self: Room, seconds: number): boolean
    local dt = math.min(seconds, 0.05)
    self.time += dt
    self.screenTimer -= dt
    Art.step(self.telemetry, dt)
    Sim.apply(self.ui.sim, self.telemetry)
    Art.stepTrend(self.telemetry, dt)

    local game = Sim.game(self.ui.sim)
    if game ~= nil then Games.step(game, dt) end
    local paused = game ~= nil -- the room waits while a mini game is open
    local turn = if paused then 0 else held(self, KEY_RIGHT) - held(self, KEY_LEFT)
    local tilt = if paused then 0 else held(self, KEY_UP) - held(self, KEY_DOWN)
    self.yaw += turn * TURN_SPEED * dt
    self.pitch = math.clamp(self.pitch + tilt * TILT_SPEED * dt, -1.45, 1.45)

    local forward = if paused then 0 else held(self, KEY_W) - held(self, KEY_S)
    local strafe = if paused then 0 else held(self, KEY_E) - held(self, KEY_Q)
    if forward ~= 0 or strafe ~= 0 then
        local len = math.sqrt(forward * forward + strafe * strafe)
        local running = self.keys[KEY_SPACE] == true
        local speed = if running then RUN_SPEED else WALK_SPEED
        local step = speed * dt / len
        local fx, fz = math.sin(self.yaw), -math.cos(self.yaw)
        local rx, rz = math.cos(self.yaw), math.sin(self.yaw)
        local ox, oz = self.camX, self.camZ
        local nx, nz = ox + (fx * forward + rx * strafe) * step, oz + (fz * forward + rz * strafe) * step
        -- Walking from the floor toward the foot of a stair, ease sideways into its width
        -- (only on the way in: stepping off the bottom is never held back).
        if self.feetY < 0.05 and nx < ox then
            for _, w in WALK do
                if w.stair and nx > w.x1 - 1.2 and nx < w.x1 + 0.6 and nz > w.sz0 - 0.7 and nz < w.sz1 + 0.7
                    and surfaceAt(w, nx) <= self.feetY + STEP_UP then
                    nz = math.clamp(nz, w.sz0 + 0.12, w.sz1 - 0.12)
                end
            end
        end
        -- Slide along whatever stops you: try the whole step, then easing into a standing area
        -- just beside it (stair and walkway edges), then each axis alone.
        local ex, ez = nil, nil
        if not canStand(self.feetY, nx, nz) then ex, ez = easeIn(self.feetY, ox, oz, nx, nz) end
        if canStand(self.feetY, nx, nz) then
            self.camX, self.camZ = nx, nz
        elseif ex ~= nil and ez ~= nil then
            self.camX, self.camZ = ex, ez
        elseif canStand(self.feetY, nx, oz) then
            self.camX = nx
        elseif canStand(self.feetY, ox, nz) then
            self.camZ = nz
        end
        collide(self)
    end
    -- Jumping: a hop above wherever you stand (walking rules still follow your feet on the ground).
    if self.jumpH > 0 or self.jumpV > 0 then
        self.jumpV -= GRAVITY * dt
        self.jumpH = math.max(0, self.jumpH + self.jumpV * dt)
        if self.jumpH <= 0 then self.jumpV = 0 end
    end
    -- Follow the ground: up a stair at once, down at a falling pace.
    local ground = groundAt(self.feetY, self.camX, self.camZ)
    if ground >= self.feetY then
        self.feetY = ground
    else
        self.feetY = math.max(ground, self.feetY - dt * 7)
    end
    local moving = forward ~= 0 or strafe ~= 0
    local running = moving and self.keys[KEY_SPACE] == true
    local amp = if running then BOB_RUN elseif moving then BOB_WALK else 0
    self.bobAmp += (amp - self.bobAmp) * (1 - math.exp(-dt * 7))
    if moving then
        self.bobPhase += dt * math.pi * (if running then STEPS_RUN else STEPS_WALK)
    elseif self.bobAmp < 0.001 then
        self.bobPhase = 0
    end
    -- Down on each footstep (|sin|), the sway swings once per two steps.
    self.eyeY = self.feetY + self.jumpH + EYE_HEIGHT + self.bobAmp * (math.abs(math.sin(self.bobPhase)) * 2 - 1.2)
    local sway = self.bobAmp * 0.45 * math.sin(self.bobPhase)
    self.swayX, self.swayZ = math.cos(self.yaw) * sway, math.sin(self.yaw) * sway
    mixSound(self, dt)
    mixAlarm(self)
    linkPage(self)
    stepTraining(self, dt)
    govern(self, seconds)
    return true
end

function keyboardEvent(self: Room, event: KeyboardEvent): boolean
    -- The web page reports its device pixel ratio as key PAGE_SCALE_KEY + ratio * 100,
    -- since the web runtime hands resize a scale of 1 on Retina screens.
    if event.key >= PAGE_SCALE_KEY then
        if event.phase ~= "up" then
            self.pageScale = math.clamp((event.key - PAGE_SCALE_KEY) / 100, 1, 4)
            local scale = math.max(self.hostScale, self.pageScale)
            if scale ~= self.scale then
                self.scale = scale
                self.targetsDirty = true
            end
        end
        return true
    end
    if event.key == SOUND_OFF_KEY or event.key == SOUND_ON_KEY then
        if event.phase ~= "up" then self.soundOn = event.key == SOUND_ON_KEY end
        return true
    end
    self.keys[event.key] = event.phase ~= "up"
    if event.key == KEY_R and event.phase == "down" and self.jumpH <= 0 and Sim.game(self.ui.sim) == nil then
        self.jumpV = JUMP_SPEED
        self.jumpH = 0.001
    end
    if event.key == 256 and event.phase ~= "up" and Sim.game(self.ui.sim) ~= nil then
        Sim.closeGame(self.ui.sim) -- Escape leaves the mini game
        layoutCard(self)
        return true
    end
    if event.key == 256 and event.phase ~= "up" and self.ui.selected ~= nil then
        self.ui.selected = nil -- Escape closes the inspect panel
    end
    return true
end


-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

local function fullscreen(canvas: GPUCanvas, view: GPUTextureView, pipeline: GPUPipeline, group: GPUBindGroup, clear: GPUColor)
    local pass = canvas:beginRenderPass({ color = { { view = view, loadOp = "clear", storeOp = "store", clearColor = clear } } })
    pass:setPipeline(pipeline)
    pass:setBindGroup(0, group)
    pass:draw(3)
    pass:finish()
end

-- Triangle ranges ({ first, count }) of each inspect id, merged where contiguous.
local pickRanges: { [string]: { { number } } }? = nil
local function rangesOf(id: string): { { number } }
    if pickRanges == nil then
        local t: { [string]: { { number } } } = {}
        for _, ob in Meta.objects do
            local key = ob.pick
            if string.sub(key, 1, 5) == "leak:" then key = string.sub(key, 1, 7) end
            if key ~= "" then
                local list = t[key]
                if list == nil then list = {}; t[key] = list end
                local last = list[#list]
                if last ~= nil and last[1] + last[2] == ob.first then
                    last[2] += ob.count
                else
                    table.insert(list, { ob.first, ob.count })
                end
            end
        end
        pickRanges = t
    end
    return (pickRanges :: any)[id] or {}
end

-- What glows this frame: the current step's targets not yet reached.
local function glowRanges(self: Room): { { number } }
    local out = {}
    local m = Sim.markers(self.ui.sim)
    if m == nil then return out end
    local wet = leakShimmer(self, m)
    if wet ~= nil then
        for _, rg in rangesOf(wet) do table.insert(out, rg) end
    end
    for _, id in m.targets do
        if not m.done[id] then
            for _, rg in rangesOf(id) do table.insert(out, rg) end
        end
    end
    return out
end

local function drawScene(g: any, pass: GPURenderPass)
    pass:setVertexBuffer(0, g.vertexBuffer)
    pass:setIndexBuffer(g.indexBuffer, "uint32")
    pass:drawIndexed(g.indexCount)
end

function draw(self: Room, renderer: Renderer)
    local context = self.context
    if not self.ready and context ~= nil then
        setupGpu(self, context)
    end
    if not self.ready or self.size.x <= 0 or self.size.y <= 0 then
        return
    end
    local g = self.g
    local canvas: GPUCanvas = g.canvas
    if self.targetsDirty then
        buildTargets(self)
    end

    -- 2D art first: the label atlas once, the screens a few times a second.
    if not self.labelsPainted then
        local frame = g.atlas[1]:beginFrame({ clearColor = 0x00000000 })
        Art.paintLabels(frame, self.cells, self.fonts)
        g.atlas[1]:endFrame()
        -- Paint both live atlases on the first frame too. The web runtime defers
        -- resources, and a bind group whose canvas hasn't been painted yet fails to
        -- resolve and drops every draw that uses it; alternating starts after this.
        for tex = 2, 3 do
            local screen = g.atlas[tex]:beginFrame({ clearColor = 0xFF000000 })
            Art.paintScreens(screen, self.cells, self.fonts, self.telemetry, tex)
            g.atlas[tex]:endFrame()
        end
        self.screenTimer = 1 / SCREEN_TICK_HZ
        self.labelsPainted = true
    end
    local prof = self.prof
    if self.screenTimer <= 0 then
        local t0 = os.clock()
        self.screenTimer = 1 / SCREEN_TICK_HZ
        local tex = self.screenTex
        self.screenTex = if tex == 2 then 3 else 2
        local frame = g.atlas[tex]:beginFrame({ clearColor = 0xFF000000 })
        Art.paintScreens(frame, self.cells, self.fonts, self.telemetry, tex)
        g.atlas[tex]:endFrame()
        local dt = os.clock() - t0
        prof.screens += dt
        prof.screensMax = math.max(prof.screensMax, dt)
    end
    local t1 = os.clock()

    -- Frame uniforms
    local cp = math.cos(self.pitch)
    local ex, ey, ez = self.camX + self.swayX, self.eyeY, self.camZ + self.swayZ
    local eye = Vector.xyz(ex, ey, ez)
    local target = Vector.xyz(ex + math.sin(self.yaw) * cp, ey + math.sin(self.pitch), ez - math.cos(self.yaw) * cp)
    local view = Mat4.lookAt(eye, target, Vector.xyz(0, 1, 0))
    local proj = Mat4.perspective(math.rad(FOV_DEGREES), self.width / self.height, NEAR, FAR)
    local bytes = g.bytes;
    (proj * view):writeToBuffer(bytes, 0)
    buffer.writef32(bytes, 64, ex); buffer.writef32(bytes, 68, ey); buffer.writef32(bytes, 72, ez); buffer.writef32(bytes, 76, 1)
    buffer.writef32(bytes, 80, self.time); buffer.writef32(bytes, 84, self.width); buffer.writef32(bytes, 88, self.height)
    updateLights(self, g) -- the nearest fixtures follow you down the hall
    local gm: any = Sim.markers(self.ui.sim)
    -- params.w: pipe highlight, plus 10 for a red glow (alarm switch) or 20 for a blue one (water).
    buffer.writef32(bytes, 92, self.ui.highlight + (if gm ~= nil and gm.red then 10 elseif leakShimmer(self, gm) ~= nil then 20 else 0))
    for i, a in Meta.anims do
        local o = ANIMS_OFFSET + (i - 1) * 32
        buffer.writef32(bytes, o, a.pivot[1]); buffer.writef32(bytes, o + 4, a.pivot[2]); buffer.writef32(bytes, o + 8, a.pivot[3]); buffer.writef32(bytes, o + 12, self.ui.angle[i])
        buffer.writef32(bytes, o + 16, a.axis[1]); buffer.writef32(bytes, o + 20, a.axis[2]); buffer.writef32(bytes, o + 24, a.axis[3]); buffer.writef32(bytes, o + 28, self.ui.lift[i])
    end
    g.ubo:write(bytes)

    -- Shadow map: the room is static, so a few frames are enough.
    if self.shadowFrames < 3 then
        self.shadowFrames += 1
        local pass = canvas:beginRenderPass({ depthStencil = { view = g.shadowView, depthLoadOp = "clear", depthStoreOp = "store", depthClearValue = 1 } })
        pass:setPipeline(g.shadowPipeline)
        pass:setBindGroup(0, g.frameGroup)
        drawScene(g, pass)
        pass:finish()
    end

    -- Camera depth pre-pass, then contact AO and its blur.
    local pre = canvas:beginRenderPass({ depthStencil = { view = g.prepassView, depthLoadOp = "clear", depthStoreOp = "store", depthClearValue = 1 } })
    pre:setPipeline(g.depthPipeline)
    pre:setBindGroup(0, g.frameGroup)
    drawScene(g, pre)
    pre:finish()
    local white = CLEAR_WHITE
    if self.ssaoOn then
        fullscreen(canvas, g.aoTargets[1], g.ssaoPipeline, g.ssaoGroup, white)
        fullscreen(canvas, g.aoTargets[2], g.blurPipeline, g.aoBlurGroups[1], white)
        fullscreen(canvas, g.aoTargets[3], g.blurPipeline, g.aoBlurGroups[2], white)
        self.aoCleared = false
    elseif not self.aoCleared then
        -- Without SSAO the contact term is a plain white texture.
        local clear = canvas:beginRenderPass({ color = { { view = g.aoTargets[1], loadOp = "clear", storeOp = "store", clearColor = white } } })
        clear:finish()
        self.aoCleared = true
    end

    -- Main pass, 4x MSAA resolved into the canvas.
    local clear = CLEAR_ROOM
    local color: ColorAttachment = if g.samples > 1 and g.msaaView ~= nil
        then { view = g.msaaView, resolveTarget = canvas:colorView(), loadOp = "clear", storeOp = "discard", clearColor = clear }
        else { loadOp = "clear", storeOp = "store", clearColor = clear }
    local pass = canvas:beginRenderPass({
        color = { color },
        depthStencil = { view = g.depthView, depthLoadOp = "clear", depthStoreOp = "discard", depthClearValue = 1 },
    })
    pass:setPipeline(g.litPipelines[g.samples])
    pass:setBindGroup(0, g.frameGroup)
    pass:setBindGroup(1, g.surfaceGroup)
    pass:setBindGroup(2, g.contactGroup)
    drawScene(g, pass)
    local glow = glowRanges(self)
    if #glow > 0 then
        pass:setPipeline(g.glowPipelines[g.samples])
        for _, rg in glow do pass:drawIndexed(rg[2] * 3, 1, rg[1] * 3) end
        pass:setPipeline(g.shellPipelines[g.samples])
        for _, rg in glow do pass:drawIndexed(rg[2] * 3, 1, rg[1] * 3) end
    end
    pass:finish()

    -- Bloom: gather the bright parts at half and quarter size, then add them back.
    if self.bloomOn then
        local black = CLEAR_BLACK
        for i = 1, 6 do
            fullscreen(canvas, g.bloomTargets[i], g.blurPipeline, g.bloomGroups[i], black)
        end
        local comp = canvas:beginRenderPass({ color = { { loadOp = "load", storeOp = "store" } } })
        comp:setPipeline(g.bloomPipeline)
        comp:setBindGroup(0, g.bloomComposite)
        comp:draw(3)
        comp:finish()
    end
    local enc = os.clock() - t1
    prof.encode += enc
    prof.encodeMax = math.max(prof.encodeMax, enc)
    prof.frames += 1
    if PERF.profile and prof.frames % 300 == 0 then
        print(string.format("PROFILE cpu ms/frame: encode %.3f (max %.3f)  screens %.3f per frame (max %.2f per paint)  tier %d  %dx%d",
            prof.encode / 300 * 1000, prof.encodeMax * 1000, prof.screens / 300 * 1000, prof.screensMax * 1000, self.tier, self.width, self.height))
        prof.encode, prof.encodeMax, prof.screens, prof.screensMax = 0, 0, 0, 0
    end

    -- Composite into the artboard (the canvas is in device pixels, scaled by quality).
    renderer:save()
    renderer:transform(Mat2D.withScale(self.size.x / self.width, self.size.y / self.height))
    renderer:drawImage(canvas.image, ImageSampler("clamp", "clamp", "bilinear"), "srcOver", 1)
    renderer:restore()

    renderer:save()
    renderer:transform(Mat2D.withTranslation(self.size.x / 2, self.size.y / 2))
    renderer:drawPath(self.crosshair, self.crosshairPaint)
    renderer:restore()
    drawGuides(self, renderer)
    drawUi(self, renderer)
    drawGame(self, renderer)
    drawFx(self, renderer)
end

return function(context: Context): Layout<Room>
    local crosshair = Path.new()
    crosshair:moveTo(Vector.xy(-6, -1))
    crosshair:lineTo(Vector.xy(6, -1))
    crosshair:lineTo(Vector.xy(6, 1))
    crosshair:lineTo(Vector.xy(-6, 1))
    crosshair:close()
    crosshair:moveTo(Vector.xy(-1, -6))
    crosshair:lineTo(Vector.xy(1, -6))
    crosshair:lineTo(Vector.xy(1, 6))
    crosshair:lineTo(Vector.xy(-1, 6))
    crosshair:close()

    return {
        context = nil,
        shaderWarned = false,
        g = nil,
        ready = false,

        size = Vector.xy(0, 0),
        scale = 1,
        hostScale = 1,
        soundOn = true,
        pageScale = 1,
        quality = 1,
        tier = 1,
        tierCap = 1,
        lastRaise = -100,
        bloomOn = PERF.bloom,
        ssaoOn = PERF.ssao,
        screenTex = 2,
        targetsDirty = true,
        width = 1,
        height = 1,

        -- Start near the door, facing the chiller.
        camX = 0,
        camZ = 4.5,
        yaw = 0,
        pitch = -0.08,
        keys = {},

        time = 0,
        screenTimer = 0,
        labelsPainted = false,
        shadowFrames = 0,
        slowFrames = 0,
        slowTimer = 0,
        calmTimer = 0,
        telemetry = Art.telemetry(),
        cells = {},
        fonts = { body = nil, bold = nil, mono = nil },
        loops = {},
        alarmSource = nil,
        alarmSound = nil,
        alarmNext = 0,
        vm = nil, vmReport = nil, vmSync = nil, reportSeq = 0, reportLog = {}, lastSync = "",
        bobPhase = 0,
        bobAmp = 0,
        eyeY = EYE_HEIGHT,
        feetY = 0,
        jumpH = 0,
        jumpV = 0,
        swayX = 0,
        swayZ = 0,
        prof = { frames = 0, screens = 0, screensMax = 0, encode = 0, encodeMax = 0 },
        aoCleared = false,

        crosshair = crosshair,
        crosshairPaint = Paint.with({ color = Color.rgba(255, 255, 255, 170) }),
        ui = newUi(),

        init = init,
        resize = resize,
        advance = advance,
        keyboardEvent = keyboardEvent,
        pointerDown = pointerDown,
        pointerMove = pointerMove,
        pointerUp = pointerUp,
        pointerExit = pointerExit,
        draw = draw,
    }
end
