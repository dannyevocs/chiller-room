// Lit shading for the chiller room. Techniques follow Data Hall 01's lit.wgsl:
// rectangular ceiling-panel lights with GGX specular, a top-down shadow map,
// screen-space contact AO, ACES tone mapping and display gamma out.
//
// Vertex colours are display values; they are linearized here. Surface kind
// and its parameter come from the material bytes (see the Blender exporter):
//   0 generic   1 floor   2 ceiling   3 wall    4 flowing pipe   5 glass
//   6 blinking  7 concrete 8 screen   9 label (atlas quad; param = frame index)
//   10 animated part   11 window glass (the landscape outside, drawn at the far plane behind
//   anything real out there)   12 outdoor surface (sun and sky light; param 1 corrugated, 2 concrete, 3 fill,
//   4 metal wall panels, 5 louvre, 6 roll-up door, 7 chain-link fabric)
// Float literals need a decimal point for the Rive WGSL compiler.

struct Frame {
    viewProj: mat4x4f,
    camPos: vec4f,               // xyz eye, w unused
    params: vec4f,               // x time, y width px, z height px, w unused
    lightViewProj: mat4x4f,      // world -> shadow map clip space
    lights: array<vec4f, 12>,    // xyz panel centre, w intensity
    frames: array<vec4f, 512>,   // 128 atlas frames x (origin+tex, u+1/|u|^2, v+1/|v|^2, uv rect)
    anims: array<vec4f, 128>,    // 64 animated parts x (pivot + angle, axis + 0)
};

@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var shadowMap: texture_depth_2d;
@group(1) @binding(1) var shadowSampler: sampler_comparison;
@group(1) @binding(2) var labelAtlas: texture_2d<f32>;
@group(1) @binding(3) var linearSampler: sampler;
@group(1) @binding(4) var screenAtlas: texture_2d<f32>;   // the chiller HMI
@group(1) @binding(5) var smallAtlas: texture_2d<f32>;    // drives, monitor, gauges
@group(2) @binding(0) var contactAO: texture_2d<f32>;

struct VIn {
    @location(0) pos: vec3f,
    @location(1) normal: vec4f,   // snorm8x4
    @location(2) color: vec4f,    // unorm8x4: rgb display colour, a = emissive
    @location(3) mat: vec4f,      // unorm8x4: roughness, metallic, kind/255, param/255
};

struct VOut {
    @builtin(position) clip: vec4f,
    @location(0) world: vec3f,
    @location(1) normal: vec3f,
    @location(2) color: vec4f,
    @location(3) mat: vec4f,
};

const PI = 3.14159265;
const ROOM_X = 10.0;
const ROOM_Z = 7.0;
const CEILING = 6.0;
const PANEL_HALF = vec2f(0.58, 0.06);   // linear LED fixtures, 1.2 m x 0.12 m lenses
const FOG = vec3f(0.017, 0.021, 0.027);


// Kind 10: a part that turns about its own axis (training valve handwheels) or moves up and down.
fn animate(pos: vec3f, mat: vec4f) -> vec3f {
    let kind = i32(mat.z * 255.0 + 0.5);
    if (kind != 10) {
        return pos;
    }
    let slot = clamp(i32(mat.w * 255.0 + 0.5) - 1, 0, 15) * 2;
    let pv = frame.anims[slot];
    let k = normalize(frame.anims[slot + 1].xyz);
    let d = pos - pv.xyz;
    let c = cos(pv.w);
    let s = sin(pv.w);
    // The axis's w lifts or drops the part (training leaks: falling drops, hidden below the floor).
    let lift = vec3f(0.0, frame.anims[slot + 1].w, 0.0);
    return pv.xyz + d * c + cross(k, d) * s + k * dot(k, d) * (1.0 - c) + lift;
}

fn animateDir(n: vec3f, mat: vec4f) -> vec3f {
    let kind = i32(mat.z * 255.0 + 0.5);
    if (kind != 10) {
        return n;
    }
    let slot = clamp(i32(mat.w * 255.0 + 0.5) - 1, 0, 15) * 2;
    let pv = frame.anims[slot];
    let k = normalize(frame.anims[slot + 1].xyz);
    let c = cos(pv.w);
    let s = sin(pv.w);
    return n * c + cross(k, n) * s + k * dot(k, n) * (1.0 - c);
}

@vertex
fn vs(v: VIn) -> VOut {
    var o: VOut;
    let pos = animate(v.pos, v.mat);
    o.clip = frame.viewProj * vec4f(pos, 1.0);
    if (i32(v.mat.z * 255.0 + 0.5) == 11) {
        o.clip.z = o.clip.w * 0.99999;   // glass: the view sits behind the cooling towers and yard
    }
    o.world = pos;
    o.normal = animateDir(v.normal.xyz, v.mat);
    o.color = v.color;
    o.mat = v.mat;
    return o;
}

fn hash2(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

fn valueNoise(p: vec2f) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash2(i);
    let b = hash2(i + vec2f(1.0, 0.0));
    let c = hash2(i + vec2f(0.0, 1.0));
    let d = hash2(i + vec2f(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn toLinear(c: vec3f) -> vec3f {
    return pow(max(c, vec3f(0.0, 0.0, 0.0)), vec3f(2.2, 2.2, 2.2));
}

// A dark line of the given width (metres) on a grid, antialiased by the pixel footprint.
fn gridLine(p: vec2f, cell: vec2f, width: f32, fw: vec2f) -> f32 {
    let t = fract(p / cell) * cell;
    let d = min(t, cell - t);
    let line = 1.0 - smoothstep(vec2f(width, width), vec2f(width, width) + fw * 1.5, d);
    return max(line.x, line.y);
}

// How lit a point is from overhead, 0 to 1: a 3x3 PCF over the shadow map.
fn shadowAt(world: vec3f, n: vec3f) -> f32 {
    let lp = frame.lightViewProj * vec4f(world + n * (0.02 + 0.06 * (1.0 - abs(n.y))), 1.0);
    let ndc = lp.xyz / lp.w;
    let uv = vec2f(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let texel = 1.0 / 2048.0;
    var lit = 0.0;
    for (var y = -1; y <= 1; y = y + 1) {
        for (var x = -1; x <= 1; x = x + 1) {
            lit = lit + textureSampleCompareLevel(shadowMap, shadowSampler,
                uv + vec2f(f32(x), f32(y)) * texel * 1.5, ndc.z - 0.0015);
        }
    }
    return lit / 9.0;
}

// Room-scale occlusion: darker toward corners, where walls meet floor and ceiling.
fn roomAO(world: vec3f, n: vec3f) -> f32 {
    let toWall = min(ROOM_X - abs(world.x), ROOM_Z - abs(world.z));
    if (n.y > 0.5) {
        return mix(0.6, 1.0, smoothstep(0.0, 0.8, toWall));
    }
    if (n.y < -0.5) {
        return mix(0.7, 1.0, smoothstep(0.0, 0.7, toWall));
    }
    return mix(0.55, 1.0, smoothstep(0.0, 0.45, world.y)) * mix(0.75, 1.0, smoothstep(0.0, 0.6, CEILING - world.y));
}

fn ggx(n: vec3f, v: vec3f, l: vec3f, rough: f32, f0: vec3f) -> vec3f {
    let h = normalize(v + l);
    let nl = max(dot(n, l), 0.0);
    let nv = max(dot(n, v), 0.001);
    let nh = max(dot(n, h), 0.0);
    let vh = max(dot(v, h), 0.0);
    let a = rough * rough;
    let a2 = a * a;
    let dd = nh * nh * (a2 - 1.0) + 1.0;
    let d = a2 / (PI * dd * dd);
    let k = (rough + 1.0) * (rough + 1.0) / 8.0;
    let g = (nv / (nv * (1.0 - k) + k)) * (nl / (nl * (1.0 - k) + k));
    let f = f0 + (vec3f(1.0, 1.0, 1.0) - f0) * pow(1.0 - vh, 5.0);
    return d * g * f / (4.0 * nv + 0.0001);
}

fn panelPoint(center: vec3f, p: vec3f) -> vec3f {
    let q = clamp(p.xz - center.xz, -PANEL_HALF, PANEL_HALF);
    return vec3f(center.x + q.x, center.y, center.z + q.y);
}

fn aces(x: vec3f) -> vec3f {
    return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), vec3f(0.0, 0.0, 0.0), vec3f(1.0, 1.0, 1.0));
}

// Tone map, fog, a soft vignette, then display gamma (the canvas is plain 8-bit).
fn finish(rgb: vec3f, world: vec3f, frag: vec2f) -> vec3f {
    let dist = length(frame.camPos.xyz - world);
    let fog = clamp(1.0 - exp(-dist * 0.018), 0.0, 1.0);
    var c = mix(aces(rgb * 1.05), FOG * 6.0, fog);
    let uv = frag / max(frame.params.yz, vec2f(1.0, 1.0)) - vec2f(0.5, 0.5);
    c = c * (1.0 - 0.28 * pow(length(uv) * 1.35, 2.4));
    return pow(max(c, vec3f(0.0, 0.0, 0.0)), vec3f(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
}

// Planar UV of a point inside an atlas frame; z = 0 when the point is outside it.
fn atlasUV(index: i32, world: vec3f) -> vec4f {
    let i = clamp(index - 1, 0, 127) * 4;
    let o = frame.frames[i];
    let u = frame.frames[i + 1];
    let v = frame.frames[i + 2];
    let rect = frame.frames[i + 3];
    let d = world - o.xyz;
    let s = dot(d, u.xyz) * u.w;
    let t = 1.0 - dot(d, v.xyz) * v.w;
    let inside = select(0.0, 1.0, s >= 0.0 && s <= 1.0 && t >= 0.0 && t <= 1.0 && o.w > 0.5);
    return vec4f(rect.xy + vec2f(s, t) * rect.zw, inside, o.w);
}

fn sampleAtlas(a: vec4f) -> vec4f {
    let l = textureSampleLevel(labelAtlas, linearSampler, a.xy, 0.0);
    let s = textureSampleLevel(screenAtlas, linearSampler, a.xy, 0.0);
    let m = textureSampleLevel(smallAtlas, linearSampler, a.xy, 0.0);
    let c = select(select(l, s, a.w > 1.5), m, a.w > 2.5);
    // Canvases are premultiplied; un-premultiply where the art has holes.
    return vec4f(c.rgb / max(c.a, 0.001), c.a * a.z);
}

// ---- The view through the windows (kind 11): a landscape at golden hour, drawn along each
// view ray, so it holds still at any distance as you walk. Ground and lake are a plane at the
// building's floor level (they shift with you); sky, clouds and mountains are at infinity.
const SUN = vec3f(-0.80, 0.2, 0.565);   // low in the west-south-west (+z is south, -x west)
const SUN_COL = vec3f(1.6, 1.15, 0.7);
const HAZE = vec3f(0.62, 0.62, 0.68);

fn fbm(p: vec2f) -> f32 {
    var s = 0.0;
    var a = 0.5;
    var q = p;
    for (var i = 0; i < 5; i = i + 1) {
        s = s + a * valueNoise(q);
        q = q * 2.03 + vec2f(17.1, 9.3);
        a = a * 0.5;
    }
    return s;
}

// Ridged rock relief on a mountain face, at compass direction u and elevation e. The noise
// coordinate is u scaled by a radius that grows with e: continuous all the way round.
fn relief(u: vec2f, e: f32, f: f32) -> f32 {
    let q = u * f * (1.0 + e);   // as dense up the face as across it
    let n = valueNoise(q) * 0.55 + valueNoise(q * 2.1 + vec2f(3.0, 1.0)) * 0.3 + valueNoise(q * 4.3) * 0.15;
    return 1.0 - abs(n * 2.0 - 1.0);
}

fn skyColor(rd: vec3f, time: f32) -> vec3f {
    let h = max(rd.y, 0.0);
    // Warm at the horizon, clear blue above, deep blue overhead.
    var c = mix(vec3f(1.1, 0.8, 0.52), vec3f(0.36, 0.58, 0.95), smoothstep(0.0, 0.22, h));
    c = mix(c, vec3f(0.06, 0.2, 0.62), smoothstep(0.15, 0.85, h));
    let sd = max(dot(rd, SUN), 0.0);
    c = c + SUN_COL * (0.35 * pow(sd, 6.0) + 0.6 * pow(sd, 60.0));
    c = c + SUN_COL * 18.0 * smoothstep(0.9993, 0.9997, sd);   // the disc
    if (rd.y > 0.005) {
        let p = rd.xz / (rd.y + 0.06) * 0.9 + vec2f(time * 0.012, time * 0.004);
        let n = fbm(p * 1.3);
        let cover = smoothstep(0.5, 0.78, n) * smoothstep(0.005, 0.2, rd.y);
        let thick = smoothstep(0.55, 0.95, n);
        let lit = mix(vec3f(1.3, 1.02, 0.85), vec3f(0.5, 0.44, 0.55), thick) + SUN_COL * 0.8 * pow(sd, 4.0);
        c = mix(c, lit, cover * 0.9);
    }
    return c;
}

// Ridge heights, as the tangent of their elevation, around the horizon: a periodic function of
// the compass direction u (unit vector in xz).
fn ridge(u: vec2f, layer: i32) -> f32 {
    if (layer == 0) {
        // The far range: tall and jagged, highest to the south and south-west.
        let n = fbm(u * 2.6 + vec2f(3.0, 7.0));
        let peaks = 1.0 - abs(valueNoise(u * 7.0 + vec2f(1.0, 2.0)) * 2.0 - 1.0);
        return (0.03 + 0.2 * n * n + 0.06 * peaks * peaks * n) * (0.45 + 0.75 * smoothstep(-0.6, 0.8, u.y - 0.3 * u.x));
    } else if (layer == 1) {
        return 0.015 + 0.075 * fbm(u * 4.0 + vec2f(11.0, 4.0));
    }
    return 0.006 + 0.03 * fbm(u * 8.0 + vec2f(2.0, 19.0));   // forested foothills
}

// Sky and mountain ranges along rd (all at infinity).
fn distantView(rd: vec3f, time: f32) -> vec3f {
    let k = max(length(rd.xz), 0.0001);
    let u = rd.xz / k;
    let e = rd.y / k;
    var c = skyColor(rd, time);
    let tng = vec2f(-u.y, u.x);
    let sunSide = dot(tng, normalize(SUN.xz));
    let lightAmt = vec3f(0.30, 0.34, 0.44) + SUN_COL * 0.55;
    for (var layer = 0; layer < 3; layer = layer + 1) {
        let h = ridge(u, layer);
        if (e < h && e > -0.02) {
            let h2 = ridge(normalize(u + tng * 0.01), layer);
            let slope = (h2 - h) / 0.01;
            // Facets lit from the sun's side, strongest near the crest, with rock strata below.
            let crest = smoothstep(0.0, h + 0.001, e);
            let f = select(select(40.0, 24.0, layer == 1), 13.0, layer == 0);
            let st = 0.25 / f;
            let r0 = relief(u, e, f);
            let rE = relief(u, e + st, f) - r0;                          // up the face
            let rA = relief(normalize(u + tng * st), e, f) - r0;         // across it
            let rock = r0;
            let face = clamp(0.62 + (rA * sunSide * 1.6 - rE * 0.8) + slope * sunSide * 0.5 * crest + 0.2 * (r0 - 0.5), 0.18, 1.35);
            var col: vec3f;
            var haze: f32;
            if (layer == 0) {
                col = vec3f(0.17, 0.19, 0.26);
                let snowLine = h * 0.58 + 0.04 * (rock - 0.5) + 0.01 + rE * 0.08;
                if (e > snowLine) {
                    col = vec3f(0.95, 0.95, 0.98);
                }
                haze = 0.26;
            } else if (layer == 1) {
                col = vec3f(0.12, 0.18, 0.17);
                haze = 0.2;
            } else {
                col = vec3f(0.06, 0.13, 0.05) * (0.7 + 0.6 * valueNoise(u * 600.0 + vec2f(0.0, e * 900.0)));
                haze = 0.06;
            }
            let lit = col * lightAmt * face;
            // Thicker haze at the foot of each range than at its crest.
            c = mix(lit, HAZE, clamp(haze + 0.12 * (1.0 - crest), 0.0, 0.9));
        }
    }
    return c;
}

// The view along rd from a point at height eye above the ground, with the ground origin at oxz.
// The tower row's box, for its shadow on the ground (tools/cooling_towers.py).
const TOWER_MIN = vec3f(3.6, 0.0, 25.0);
const TOWER_MAX = vec3f(22.3, 6.6, 33.0);

fn towerShadow(p: vec2f) -> f32 {
    let o = vec3f(p.x, 0.0, p.y);
    let inv = 1.0 / SUN;
    let t0 = (TOWER_MIN - o) * inv;
    let t1 = (TOWER_MAX - o) * inv;
    let tmin = max(max(min(t0.x, t1.x), min(t0.y, t1.y)), min(t0.z, t1.z));
    let tmax = min(min(max(t0.x, t1.x), max(t0.y, t1.y)), max(t0.z, t1.z));
    return select(1.0, 0.45, tmax > max(tmin, 0.0));
}

fn landscape(rd: vec3f, oxz: vec2f, eye: f32, time: f32) -> vec3f {
    var c = distantView(rd, time);
    let lightAmt = vec3f(0.30, 0.34, 0.44) + SUN_COL * 0.55;
    if (rd.y < 0.0) {
        let t = eye / -rd.y;
        let p = oxz + rd.xz * t;
        let far = 1.0 - exp(-t * 0.0007);
        // Meadow, with forest patches thinning out toward the lake.
        let m = fbm(p * 0.02);
        var g = mix(vec3f(0.16, 0.24, 0.06), vec3f(0.32, 0.34, 0.1), m);
        let detail = 1.0 - smoothstep(30.0, 400.0, t);
        g = g * (0.85 + 0.3 * valueNoise(p * 0.7) * detail);
        let forest = smoothstep(0.52, 0.6, fbm(p * 0.006 + vec2f(5.0, 1.0)) + 0.08 * valueNoise(p * 0.15));
        let trees = mix(0.6, 1.0, valueNoise(p * 0.45) * detail + (1.0 - detail) * 0.5);
        g = mix(g, vec3f(0.04, 0.09, 0.04) * trees, forest);
        // A gravel apron and a service road round the building.
        let bx = max(max(-10.0 - p.x, p.x - 38.0), 0.0);
        let bz = max(max(-7.0 - p.y, p.y - 7.0), 0.0);
        var apron = 1.0 - smoothstep(5.0, 5.4, length(vec2f(bx, bz)));
        // The cooling tower yard is gravelled too.
        apron = max(apron, step(-1.0, p.x) * step(p.x, 28.0) * step(p.y, 40.0) * step(7.0, p.y));
        g = mix(g, vec3f(0.36, 0.35, 0.33) * (0.9 + 0.2 * valueNoise(p * 3.0)), apron);
        let road = 1.0 - smoothstep(2.6, 3.0, abs(p.x - 46.0 - 6.0 * sin(max(p.y, 0.0) * 0.012)));
        g = mix(g, vec3f(0.2, 0.2, 0.21), road * step(-24.0, p.y) * (1.0 - apron));
        // North of the plant: a lawn, the service road (dashed centre line), a sidewalk and the data hall's apron.
        if (p.y < -12.4 && p.y > -40.0 && p.x > -24.0 && p.x < 48.0) {
            g = mix(vec3f(0.13, 0.2, 0.06), vec3f(0.18, 0.25, 0.08), valueNoise(p * 0.3)) * (0.9 + 0.15 * valueNoise(p * 2.0) * detail);
        }
        let sRoad = (1.0 - smoothstep(-14.2, -14.0, p.y)) * smoothstep(-25.2, -25.0, p.y) * step(-80.0, p.x) * step(p.x, 49.0);
        let dash = (1.0 - smoothstep(0.06, 0.1, abs(p.y + 19.5))) * step(0.5, fract(p.x / 6.0)) * detail;
        g = mix(g, mix(vec3f(0.17, 0.17, 0.18) * (0.92 + 0.12 * valueNoise(p * 4.0)), vec3f(0.85, 0.7, 0.1), dash), sRoad);
        let walk = step(-35.0, p.y) * (1.0 - step(-33.4, p.y)) * step(-24.0, p.x) * step(p.x, 48.0);
        let pad = step(-38.0, p.y) * (1.0 - step(-35.0, p.y)) * step(-20.0, p.x) * step(p.x, 44.0);
        g = mix(g, vec3f(0.5, 0.49, 0.46) * (0.9 + 0.15 * valueNoise(p * 3.0)), max(walk, pad));
        // The fenced utility yard: crushed stone.
        let yard = step(-18.0, p.x) * step(p.x, 23.0) * step(-33.1, p.y) * (1.0 - step(-25.9, p.y));
        g = mix(g, vec3f(0.4, 0.39, 0.37) * (0.85 + 0.25 * valueNoise(p * 9.0) * detail), yard);
        var ground = g * lightAmt * mix(towerShadow(p), 1.0, step(60.0, t));
        // The lake to the south, its shore wavy.
        let lakeD = length((p - vec2f(0.0, 190.0)) / vec2f(260.0, 110.0)) + 0.3 * (fbm(p * 0.006) - 0.5);
        if (lakeD < 1.0) {
            let ripple = (valueNoise(p * vec2f(0.06, 0.25) + vec2f(time * 0.15, 0.0)) - 0.5) * 0.04 * detail;
            let rr = normalize(vec3f(rd.x + ripple, -rd.y, rd.z));
            let fres = 0.25 + 0.75 * pow(1.0 - abs(rd.y), 5.0);
            var water = mix(vec3f(0.03, 0.08, 0.12), distantView(rr, time), fres);
            water = water + SUN_COL * 4.0 * pow(max(dot(rr, SUN), 0.0), 300.0) * (0.5 + valueNoise(p * 0.8 + vec2f(time, 0.0)));
            let shore = smoothstep(0.96, 1.0, lakeD);
            ground = mix(water, vec3f(0.5, 0.45, 0.36) * lightAmt, shore);
        }
        c = mix(ground, HAZE, far);
    }
    return c;
}

// Vapour rising from the tower fans, drifting east on the breeze: a soft column per cell around
// its axis, broken up by noise. Only ever drawn behind real geometry (it's part of the view).
fn plume(ro: vec3f, rd: vec3f, c: vec3f, time: f32) -> vec3f {
    let w = normalize(vec3f(0.35, 1.0, 0.12));
    var col = c;
    for (var i = 0; i < 3; i = i + 1) {
        let a = vec3f(7.0 + 6.0 * f32(i), 6.7, 29.0);
        let w0 = ro - a;
        let b = dot(rd, w);
        let d = dot(rd, w0);
        let e = dot(w, w0);
        let s = clamp((e - b * d) / max(1.0 - b * b, 0.0001), 0.0, 14.0);
        let q = a + w * s;
        let t = dot(q - ro, rd);
        if (t > 0.0) {
            let r = length(ro + rd * t - q);
            let rad = 1.2 + s * 0.32;
            var dens = exp(-r * r / (rad * rad)) * smoothstep(-0.3, 0.6, s) * (1.0 - smoothstep(3.0, 13.0, s));
            dens = dens * smoothstep(0.3, 0.75, fbm(vec2f(s * 0.7 - time * 0.6, r * 0.9 + f32(i) * 7.0)));
            col = mix(col, vec3f(1.05, 1.0, 0.98) + SUN_COL * 0.25, clamp(dens * 0.45, 0.0, 0.4));
        }
    }
    return col;
}

// Outdoor tone mapping: aces, a little of the room's fog for the glass in between, the vignette.
fn finishOutside(c: vec3f, world: vec3f, frag: vec2f) -> vec4f {
    let dist = length(frame.camPos.xyz - world);
    var o = mix(aces(c * 1.0), FOG * 6.0, clamp(1.0 - exp(-dist * 0.005), 0.0, 1.0));
    let uv = frag / max(frame.params.yz, vec2f(1.0, 1.0)) - vec2f(0.5, 0.5);
    o = o * (1.0 - 0.28 * pow(length(uv) * 1.35, 2.4));
    return vec4f(pow(max(o, vec3f(0.0, 0.0, 0.0)), vec3f(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2)), 1.0);
}

// Glass: the view (behind any real outdoor geometry), a little cooler and darker.
fn windowView(world: vec3f, frag: vec2f) -> vec4f {
    let ro = frame.camPos.xyz;
    let rd = normalize(world - ro);
    var c = landscape(rd, ro.xz, max(ro.y, 0.5), frame.params.x);
    c = plume(ro, rd, c, frame.params.x);
    c = c * vec3f(0.92, 0.95, 0.97) + vec3f(0.01, 0.012, 0.015);
    return finishOutside(c, world, frag);
}

// Kind 12: the cooling tower yard, lit by the low sun and the sky instead of the room's panels.
fn outdoorSurface(v: VOut, param: i32) -> vec4f {
    let viewDir = normalize(frame.camPos.xyz - v.world);
    var n = normalize(v.normal);
    if (dot(n, viewDir) < 0.0) {
        n = -n;   // two-sided: louvre blades and open stacks
    }
    var base = toLinear(v.color.rgb);
    let rough = clamp(v.mat.x, 0.06, 1.0);
    let metal = v.mat.y;
    let side = abs(n.y) < 0.7;
    let t = normalize(cross(vec3f(0.0, 1.0, 0.0), select(vec3f(1.0, 0.0, 0.0), n, side)));
    let u = dot(v.world, t);
    if (param == 1 && side) {
        // Corrugated galvanized casing: ribs every 120 mm, panel seams every 1.2 m, rain streaks.
        n = normalize(n + t * 0.35 * sin(u * 52.36));
        base = base * (1.0 - 0.3 * (1.0 - smoothstep(0.0, 0.02, abs(abs(fract(u / 1.2) - 0.5) - 0.5))));
        base = base * (0.85 + 0.2 * valueNoise(vec2f(u * 3.0, v.world.y * 0.4)));
    } else if (param == 2) {
        base = base * (0.85 + 0.2 * valueNoise(v.world.xz * 4.0) + 0.06 * valueNoise(v.world.xz * 31.0));
    } else if (param == 3) {
        base = base * (0.8 + 0.4 * valueNoise(vec2f(u * 8.0, v.world.y * 0.5)));
    } else if (param == 4 && side) {
        // Insulated metal wall panels: 1 m high, 12 m long, a fine stucco grain, each a touch different.
        let row = floor(v.world.y);
        let col = floor(u / 12.0);
        base = base * (0.96 + 0.06 * hash2(vec2f(row, col))) * (0.97 + 0.04 * valueNoise(vec2f(u, v.world.y) * 40.0));
        let jy = abs(fract(v.world.y) - 0.5);
        let ju = abs(fract(u / 12.0) - 0.5) * 12.0;
        base = base * (1.0 - 0.45 * smoothstep(0.488, 0.497, jy)) * (1.0 - 0.45 * smoothstep(5.975, 5.99, ju));
        n = normalize(n + vec3f(0.0, 0.25, 0.0) * smoothstep(0.47, 0.497, jy) * sign(fract(v.world.y) - 0.5));
    } else if (param == 5) {
        // Louvre blades every 150 mm: a lit top edge, dark gaps between.
        let f = fract(v.world.y / 0.15);
        base = base * mix(0.18, 1.15, smoothstep(0.15, 0.35, f) * (1.0 - smoothstep(0.8, 0.95, f)));
        n = normalize(n + vec3f(0.0, 0.8, 0.0) * (0.5 - f));
    } else if (param == 6) {
        // Roll-up door slats every 90 mm.
        let f = fract(v.world.y / 0.09);
        base = base * (0.85 + 0.2 * smoothstep(0.1, 0.5, f) * (1.0 - smoothstep(0.85, 1.0, f)));
    } else {
        base = base * (0.94 + 0.1 * valueNoise(vec2f(u * 2.0, v.world.y * 2.0) + v.world.xz));
    }
    let ndl = max(dot(n, SUN), 0.0);
    let sky = mix(vec3f(0.17, 0.16, 0.14), vec3f(0.34, 0.44, 0.62), n.y * 0.5 + 0.5);
    let ao = select(1.0, mix(0.6, 1.0, smoothstep(0.1, 1.4, v.world.y)), side);
    let h = normalize(SUN + viewDir);
    let f0 = mix(vec3f(0.04, 0.04, 0.04), base, metal);
    let spec = SUN_COL * f0 * pow(max(dot(n, h), 0.0), mix(200.0, 8.0, rough)) * ndl * (1.0 - rough * 0.7);
    let refl = reflect(-viewDir, n);
    let env = mix(vec3f(0.2, 0.19, 0.17), vec3f(0.5, 0.62, 0.85), smoothstep(-0.2, 0.6, refl.y)) * f0 * (1.0 - rough * 0.6);
    let rgb = base * (1.0 - metal * 0.7) * (SUN_COL * ndl + sky) * ao + spec + env;
    let far = 1.0 - exp(-length(frame.camPos.xyz - v.world) * 0.0011);
    return finishOutside(mix(rgb, HAZE, far), v.world, v.clip.xy);
}

@fragment
fn fs(v: VOut) -> @location(0) vec4f {
    let kind = i32(v.mat.z * 255.0 + 0.5);
    let param = i32(v.mat.w * 255.0 + 0.5);
    var n = normalize(v.normal);
    let viewDir = normalize(frame.camPos.xyz - v.world);
    let time = frame.params.x;
    // Pixel footprints before any branch, as WGSL requires.
    let fwXZ = fwidth(v.world.xz);
    let fwXY = fwidth(v.world.xy);
    let fwZY = fwidth(v.world.zy);

    if (kind == 11) {
        return windowView(v.world, v.clip.xy);
    }
    if (kind == 12) {
        if (param == 7) {
            // Chain-link fabric: a see-through veil, about a third covered (ordered dither).
            var bayer = array<f32, 16>(0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0);
            let ip = vec2<i32>(v.clip.xy) % vec2<i32>(4, 4);
            if (bayer[ip.y * 4 + ip.x] >= 5.0) {
                discard;
            }
        }
        return outdoorSurface(v, param);
    }

    var base = toLinear(v.color.rgb);
    var rough = clamp(v.mat.x, 0.06, 1.0);
    var metal = v.mat.y;
    var emissive = v.color.a > 0.5;
    var glow = vec3f(0.0, 0.0, 0.0);

    // Atlas quads: labels (lit ones glow) and live screens. Floor stencils are painted
    // onto the floor: they take the floor's shading, then the art goes on top.
    var labelArt = vec3f(0.0, 0.0, 0.0);
    var labelA = 0.0;
    let floorLabel = kind == 9 && v.world.y < 0.01;
    if (kind == 8 || kind == 9) {
        let a = atlasUV(param, v.world);
        if (a.z > 0.5) {
            let t = sampleAtlas(a);
            let art = toLinear(t.rgb);
            let outdoors = v.world.z < -7.3 || v.world.z > 7.3 || v.world.x < -10.3 || v.world.x > 38.3;
            if (emissive && outdoors) {
                return finishOutside(art * 1.25, v.world, v.clip.xy);   // lit signs outdoors (the data hall's)
            }
            if (outdoors && !floorLabel) {
                // Signs and tags out in the yard: lit by the sun and sky, like the equipment they're on.
                var ln = n;
                if (dot(ln, viewDir) < 0.0) { ln = -ln; }
                let light = SUN_COL * max(dot(ln, SUN), 0.0) + mix(vec3f(0.17, 0.16, 0.14), vec3f(0.34, 0.44, 0.62), ln.y * 0.5 + 0.5);
                return finishOutside(art * light, v.world, v.clip.xy);
            }
            if (emissive || kind == 8) {
                let scan = 0.94 + 0.06 * sin(a.y * 1400.0);
                return vec4f(finish(art * 1.6 * scan, v.world, v.clip.xy), 1.0);
            }
            labelArt = art;
            labelA = t.a;
        } else if (kind == 8) {
            return vec4f(finish(base * 0.15, v.world, v.clip.xy), 1.0);
        }
        emissive = false;
    }

    if (emissive) {
        var level = 1.6;
        if (kind == 6) {
            // 1: amber status light, a slow breathe. 2: a strobe on standby, dim and steady.
            level = select(0.35, 0.6 + 1.6 * (0.5 + 0.5 * sin(time * 2.4)), param == 1);
        }
        if (v.world.y > 4.4) {
            level = 2.6;   // troffer lenses: brightest in the room, they bloom
        }
        return vec4f(finish(base * level, v.world, v.clip.xy), 1.0);
    }

    // ---- Surfaces
    var wear = 0.0;
    if ((kind == 1 || floorLabel) && v.world.y < 0.02) {
        // Epoxy-coated concrete: light gray, faint mottling, a fine non-slip grain, saw-cut
        // joints on a 5 x 3.5 m grid, and gentle traffic wear on the walking routes. Glossy.
        let p = v.world.xz;
        if (floorLabel) {
            base = vec3f(0.42, 0.43, 0.44);
        }
        let mottle = valueNoise(p * 0.6) * 0.6 + valueNoise(p * 2.3 + vec2f(5.0, 1.0)) * 0.4;
        base = base * (0.95 + 0.08 * mottle);
        let grain = valueNoise(p * 220.0);
        base = base * (0.985 + 0.03 * grain);
        rough = 0.24 + 0.14 * grain;
        let joint = gridLine(p + vec2f(2.5, 1.75), vec2f(5.0, 3.5), 0.003, fwXZ);
        base = base * (1.0 - 0.35 * joint);
        let toDoor = exp(-pow(p.x / 1.1, 2.0)) * smoothstep(-1.5, 2.0, p.y);
        let front = exp(-pow((p.y + 1.0) / 0.6, 2.0)) * smoothstep(-6.5, -3.0, p.x) * (1.0 - smoothstep(3.0, 5.0, p.x));
        wear = clamp(max(toDoor, front) * (0.4 + 0.6 * mottle), 0.0, 1.0);
        base = base * (1.0 - 0.04 * wear);
        rough = rough + 0.12 * wear;
    } else if (kind == 2) {
        // Lay-in ceiling tiles, 1.2 x 0.6 m, with a fissured surface.
        let p = v.world.xz;
        base = base * (0.93 + 0.07 * valueNoise(p * 40.0)) * (0.97 + 0.06 * hash2(floor(p / vec2f(1.2, 0.6))));
        base = base * (1.0 - 0.35 * gridLine(p, vec2f(1.2, 0.6), 0.010, fwXZ));
    } else if (kind == 3) {
        // Painted block walls: 400 x 200 mm running bond, a darker wainscot below 1.2 m.
        let alongX = abs(n.z) > abs(n.x);
        let u = select(v.world.z, v.world.x, alongX);
        let fw = select(fwZY, fwXY, alongX);
        let course = floor(v.world.y / 0.2);
        let shifted = vec2f(u + 0.2 * (course - 2.0 * floor(course / 2.0)), v.world.y);
        base = base * (1.0 - 0.10 * gridLine(shifted, vec2f(0.4, 0.2), 0.004, fw));
        base = base * (0.96 + 0.06 * valueNoise(vec2f(u, v.world.y) * 9.0));
        base = base * 0.78;
        if (v.world.y < 1.2) {
            base = base * vec3f(0.70, 0.75, 0.82);
        }
        let band = 1.0 - smoothstep(0.0, max(fw.y * 1.5, 0.002), abs(v.world.y - 1.2) - 0.015);
        base = mix(base, vec3f(0.06, 0.08, 0.11), band);
    } else if (kind == 7) {
        let p = v.world.xz + v.world.yy * 3.0;
        base = base * (0.85 + 0.2 * valueNoise(p * 6.0) + 0.08 * valueNoise(p * 31.0));
    } else if (kind == 4) {
        // Flowing water: soft bands drift along the pipe in its flow direction. param: circuit
        // 1 CHWS, 2 CHWR, 3 CWS, 4 CWR in the low 3 bits; +x, +y, +z flow signs in the next 3.
        let circuit = param & 7;
        let bits = param >> 3u;
        let an = abs(n);
        var along = v.world.x * select(-1.0, 1.0, (bits & 1) != 0);
        if (an.y <= an.x && an.y <= an.z) {
            along = v.world.y * select(-1.0, 1.0, (bits & 2) != 0);
        } else if (an.z <= an.x && an.z <= an.y) {
            along = v.world.z * select(-1.0, 1.0, (bits & 4) != 0);
        }
        let s = fract(along * 1.2 - time * 0.55);
        base = base * (0.92 + 0.16 * smoothstep(0.0, 0.5, s) * (1.0 - smoothstep(0.5, 1.0, s)));
        // Training highlight: the chosen circuit glows in its colour, the others dim.
        let hl = i32(frame.params.w + 0.5) % 10; // tens digit: glow colour, see glowColor
        if (hl > 0) {
            if (hl == circuit) {
                var tint = vec3f(0.15, 0.45, 1.0);
                if (circuit == 2) { tint = vec3f(0.1, 0.85, 0.9); }
                if (circuit == 3) { tint = vec3f(0.2, 0.9, 0.3); }
                if (circuit == 4) { tint = vec3f(1.0, 0.55, 0.12); }
                base = mix(base, tint, 0.65);
                glow = tint * (0.28 + 0.22 * smoothstep(0.0, 0.5, s) * (1.0 - smoothstep(0.5, 1.0, s)));
            } else {
                base = base * 0.45;
            }
        }
    } else if (kind == 5) {
        rough = 0.05;
        metal = 0.0;
    }

    if (labelA > 0.0) {
        base = mix(base, labelArt, labelA);
        rough = mix(rough, 0.5, labelA);
        metal = mix(metal, 0.0, labelA);
    }
    // Subtle roughness variation on painted and metal surfaces, so large faces don't read as plastic.
    if (kind == 0 || kind == 4) {
        rough = clamp(rough * (0.88 + 0.24 * valueNoise(v.world.xz * 3.1 + v.world.yy * 2.3)), 0.06, 1.0);
    }
    let f0 = mix(vec3f(0.04, 0.04, 0.04), base, metal);
    let diffuseColor = base * (1.0 - metal);
    // One overhead shadow stands in for twelve panels: it darkens what faces up the most,
    // while sides and undersides, lit from many angles, keep most of their light.
    let inReveal = v.world.z > 6.97 || v.world.z < -6.97 || v.world.x < -9.97 || v.world.x > 37.97;
    let shadow = select(mix(1.0, shadowAt(v.world, n), mix(0.35, 1.0, smoothstep(0.0, 0.7, n.y))), 1.0, inReveal);
    let contact = textureSampleLevel(contactAO, linearSampler, v.clip.xy / max(frame.params.yz, vec2f(1.0, 1.0)), 0.0).r;
    let ao = select(roomAO(v.world, n), 1.0, inReveal) * contact;

    var diffuse = vec3f(0.0, 0.0, 0.0);
    var spec = vec3f(0.0, 0.0, 0.0);
    let refl = reflect(-viewDir, n);
    for (var i = 0; i < 12; i = i + 1) {
        let light = frame.lights[i];
        let center = light.xyz;
        let toNear = panelPoint(center, v.world) - v.world;
        let d2 = max(dot(toNear, toNear), 0.0001);
        let l = toNear * inverseSqrt(d2);
        let down = max(l.y, 0.0);   // a panel lights below it best
        let radiance = vec3f(1.0, 0.97, 0.92) * light.w / (1.0 + 0.18 * d2);
        diffuse = diffuse + radiance * max(dot(n, l), 0.0) * (0.35 + 0.65 * down);
        var aim = center;
        if (refl.y > 0.01) {
            let hit = v.world + refl * ((center.y - v.world.y) / refl.y);
            aim = panelPoint(center, hit);
        }
        let toSpec = aim - v.world;
        let sd2 = max(dot(toSpec, toSpec), 0.0001);
        let ls = toSpec * inverseSqrt(sd2);
        let widened = clamp(rough + 0.35 / (1.0 + sd2), 0.08, 1.0);
        let norm = (rough * rough) / (widened * widened);
        spec = spec + vec3f(1.0, 0.97, 0.92) * light.w / (1.0 + 0.18 * sd2) * ggx(n, viewDir, ls, widened, f0) * norm;
    }
    // Shadowed spots keep some light: it bounces around a pale room.
    diffuse = diffuse * mix(0.3, 1.0, shadow) * mix(0.6, 1.0, ao);
    spec = spec * shadow * mix(0.5, 1.0, ao);

    let sky = vec3f(0.075, 0.082, 0.095);
    let ground = vec3f(0.028, 0.03, 0.034);
    // Light bounced off the pale floor reaches the ceiling and the undersides of things.
    let bounce = vec3f(0.11, 0.11, 0.115) * smoothstep(0.2, -0.9, n.y);
    let ambient = (mix(ground, sky, n.y * 0.5 + 0.5) + bounce) * ao;
    let env = mix(ground, sky * 2.2, smoothstep(-0.3, 0.7, refl.y)) * ao;
    let nv = max(dot(n, viewDir), 0.0);
    let fr = f0 + (max(vec3f(1.0 - rough, 1.0 - rough, 1.0 - rough), f0) - f0) * pow(1.0 - nv, 5.0);

    // Daylight through the clerestory: the reveals catch the most, the upper level a little.
    let toOuter = min(min(7.0 - abs(v.world.z), v.world.x + 10.0), 38.0 - v.world.x);
    let daylight = vec3f(0.55, 0.6, 0.7) * (select(0.0, 0.5, inReveal) +
        0.18 * smoothstep(5.5, 7.5, v.world.y) * (1.0 - smoothstep(0.0, 4.0, toOuter)));
    let rgb = diffuseColor * (ambient + diffuse + daylight) + spec + env * fr * (1.0 - rough * 0.6) + glow;
    return vec4f(finish(rgb, v.world, v.clip.xy), 1.0);
}

// Training glow: the scenario's target is drawn again, added on top (no depth
// write). fsGlow coats the object itself in breathing green (red for an alarm switch) with a bright rim;
// vsGlowShell + fsGlowShell draw it again pushed out along its normals, a halo
// that sticks out past its outline. Bright enough to feed the bloom.
const GLOW_GREEN = vec3f(0.25, 1.0, 0.35);
const GLOW_RED = vec3f(1.0, 0.12, 0.08);
const GLOW_WATER = vec3f(0.15, 0.55, 1.0);

// params.w carries the pipe highlight (0-4) plus 10 for a red glow (an alarm switch)
// or 20 for a softer blue one (a puddle of water).
fn glowColor() -> vec3f {
    if (frame.params.w > 19.5) { return GLOW_WATER * 0.6; }
    return select(GLOW_GREEN, GLOW_RED, frame.params.w > 9.5);
}

@fragment
fn fsGlow(v: VOut) -> @location(0) vec4f {
    let n = normalize(v.normal);
    let viewDir = normalize(frame.camPos.xyz - v.world);
    let time = frame.params.x;
    let rim = pow(1.0 - abs(dot(n, viewDir)), 2.0);
    let breathe = 0.5 + 0.5 * sin(time * 3.4);
    let band = smoothstep(0.7, 1.0, fract(v.world.y * 0.8 - time * 0.7));
    let rgb = glowColor() * (0.22 + 0.25 * breathe + 1.3 * rim + 0.45 * band);
    return vec4f(rgb, 0.0);
}

@vertex
fn vsGlowShell(v: VIn) -> VOut {
    var o: VOut;
    let breathe = 0.5 + 0.5 * sin(frame.params.x * 3.4);
    let n = normalize(animateDir(v.normal.xyz, v.mat));
    let pos = animate(v.pos, v.mat) + n * (0.05 + 0.03 * breathe);
    o.clip = frame.viewProj * vec4f(pos, 1.0);
    o.world = pos;
    o.normal = n;
    o.color = v.color;
    o.mat = v.mat;
    return o;
}

@fragment
fn fsGlowShell(v: VOut) -> @location(0) vec4f {
    let n = normalize(v.normal);
    let viewDir = normalize(frame.camPos.xyz - v.world);
    let rim = pow(1.0 - abs(dot(n, viewDir)), 1.5);
    let breathe = 0.5 + 0.5 * sin(frame.params.x * 3.4);
    return vec4f(glowColor() * (0.10 + 0.9 * rim) * (0.7 + 0.3 * breathe), 0.0);
}
