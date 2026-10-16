// Contact shadows: screen-space ambient occlusion from the camera's depth
// pre-pass, at half resolution (after Data Hall 01's ssao.wgsl). Each pixel
// rebuilds its view-space position and normal from depth, then checks 12
// nearby points in a spiral: those above its surface and close by occlude it.
// blur.wgsl smooths the result and room.wgsl multiplies ambient light by it.

struct Params {
    size: vec4f,    // xy full-resolution size, z tan(fovY / 2), w aspect
    depth: vec4f,   // x near, y far, z world radius, w strength
};

@group(0) @binding(0) var depthTex: texture_depth_2d;
@group(0) @binding(1) var<uniform> p: Params;

struct VOut {
    @builtin(position) pos: vec4f,
    @location(0) uv: vec2f,
};

@vertex
fn vs(@builtin(vertex_index) i: u32) -> VOut {
    var c = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    var o: VOut;
    o.pos = vec4f(c[i], 0.0, 1.0);
    o.uv = vec2f((c[i].x + 1.0) * 0.5, (1.0 - c[i].y) * 0.5);
    return o;
}

fn linearDepth(d: f32) -> f32 {
    let n = p.depth.x;
    let f = p.depth.y;
    return n * f / (f - d * (f - n));
}

fn viewPos(px: vec2f) -> vec3f {
    let c = clamp(vec2i(px), vec2i(0, 0), vec2i(p.size.xy) - vec2i(1, 1));
    let z = linearDepth(textureLoad(depthTex, c, 0));
    let ndc = vec2f(px.x / p.size.x * 2.0 - 1.0, 1.0 - px.y / p.size.y * 2.0);
    return vec3f(ndc.x * p.size.z * p.size.w * z, ndc.y * p.size.z * z, z);
}

@fragment
fn fs(v: VOut) -> @location(0) vec4f {
    let px = v.uv * p.size.xy;
    let pos = viewPos(px);
    if (pos.z > p.depth.y * 0.95) {
        return vec4f(1.0, 1.0, 1.0, 1.0);
    }
    let l = viewPos(px - vec2f(1.0, 0.0));
    let r = viewPos(px + vec2f(1.0, 0.0));
    let u = viewPos(px - vec2f(0.0, 1.0));
    let d = viewPos(px + vec2f(0.0, 1.0));
    let dx = select(pos - l, r - pos, abs(r.z - pos.z) < abs(pos.z - l.z));
    let dy = select(pos - u, d - pos, abs(d.z - pos.z) < abs(pos.z - u.z));
    let n = normalize(cross(dy, dx));
    let focal = p.size.y * 0.5 / p.size.z;
    let radiusPx = clamp(p.depth.z * focal / pos.z, 3.0, 80.0);
    let rotation = fract(sin(dot(floor(px), vec2f(12.9898, 78.233))) * 43758.5453) * 6.2832;
    var occlusion = 0.0;
    for (var i = 0; i < 12; i = i + 1) {
        let t = (f32(i) + 0.5) / 12.0;
        let a = rotation + f32(i) * 2.39996;
        let offset = vec2f(cos(a), sin(a)) * radiusPx * t;
        let q = viewPos(px + offset);
        let toQ = q - pos;
        let dist = length(toQ);
        let facing = max(dot(n, toQ / max(dist, 0.0001)) - 0.15, 0.0);
        let range = 1.0 - smoothstep(p.depth.z * 0.6, p.depth.z * 1.6, dist);
        occlusion = occlusion + facing * range;
    }
    let ao = clamp(1.0 - occlusion / 12.0 * p.depth.w, 0.0, 1.0);
    return vec4f(ao, ao, ao, 1.0);
}
