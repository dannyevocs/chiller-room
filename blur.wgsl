// A fullscreen pass that either picks out a frame's bright pixels while halving
// it (mode 0) or blurs along one axis with a 9-tap Gaussian (mode 1). Used for
// the contact AO and the bloom chain (after Data Hall 01's blur.wgsl).

struct Params {
    v: vec4f,   // xy step in UV, z mode, w brightness threshold
};

@group(0) @binding(0) var src: texture_2d<f32>;
@group(0) @binding(1) var srcSampler: sampler;
@group(0) @binding(2) var<uniform> p: Params;

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

fn tap(uv: vec2f) -> vec3f {
    return textureSampleLevel(src, srcSampler, uv, 0.0).rgb;
}

@fragment
fn fs(v: VOut) -> @location(0) vec4f {
    let s = p.v.xy;
    if (p.v.z < 0.5) {
        let c = (tap(v.uv + vec2f(-0.5, -0.5) * s) + tap(v.uv + vec2f(0.5, -0.5) * s)
            + tap(v.uv + vec2f(-0.5, 0.5) * s) + tap(v.uv + vec2f(0.5, 0.5) * s)) * 0.25;
        let peak = max(c.r, max(c.g, c.b));
        let w = smoothstep(p.v.w, p.v.w + 0.3, peak);
        return vec4f(c * w, 1.0);
    }
    var c = tap(v.uv) * 0.227027;
    c = c + (tap(v.uv + s) + tap(v.uv - s)) * 0.1945946;
    c = c + (tap(v.uv + s * 2.0) + tap(v.uv - s * 2.0)) * 0.1216216;
    c = c + (tap(v.uv + s * 3.0) + tap(v.uv - s * 3.0)) * 0.054054;
    c = c + (tap(v.uv + s * 4.0) + tap(v.uv - s * 4.0)) * 0.016216;
    return vec4f(c, 1.0);
}
