// Bloom composite: adds the blurred half- and quarter-resolution bright images
// back onto the frame, the wide one softer (after Data Hall 01's bloomcomp.wgsl).

struct Params {
    v: vec4f,   // x near strength, y wide strength
};

@group(0) @binding(0) var near: texture_2d<f32>;
@group(0) @binding(1) var wide: texture_2d<f32>;
@group(0) @binding(2) var bloomSampler: sampler;
@group(0) @binding(3) var<uniform> p: Params;

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

@fragment
fn fs(v: VOut) -> @location(0) vec4f {
    let a = textureSampleLevel(near, bloomSampler, v.uv, 0.0).rgb;
    let b = textureSampleLevel(wide, bloomSampler, v.uv, 0.0).rgb;
    return vec4f(a * p.v.x + b * p.v.y, 0.0);
}
