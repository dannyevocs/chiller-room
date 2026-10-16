// Depth-only passes: the shadow map from overhead (vs) and the camera's
// depth pre-pass for contact AO (vsCamera). The Frame struct matches room.wgsl's.

struct Frame {
    viewProj: mat4x4f,
    camPos: vec4f,
    params: vec4f,
    lightViewProj: mat4x4f,
    lights: array<vec4f, 12>,
    frames: array<vec4f, 512>,
    anims: array<vec4f, 128>,
};

@group(0) @binding(0) var<uniform> frame: Frame;

struct VIn {
    @location(0) pos: vec3f,
    @location(1) normal: vec4f,
    @location(2) color: vec4f,
    @location(3) mat: vec4f,
};


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
fn vs(v: VIn) -> @builtin(position) vec4f {
    return frame.lightViewProj * vec4f(animate(v.pos, v.mat), 1.0);
}

@vertex
fn vsCamera(v: VIn) -> @builtin(position) vec4f {
    var c = frame.viewProj * vec4f(animate(v.pos, v.mat), 1.0);
    if (i32(v.mat.z * 255.0 + 0.5) == 11) {
        c.z = c.w * 0.99999;   // window glass sits behind the yard, as in room.wgsl
    }
    return c;
}
