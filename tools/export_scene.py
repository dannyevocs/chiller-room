# Exports chiller_hifi.blend to the files main.luau loads:
#   scene_vertices.bin  24 bytes per vertex: float32x3 position, snorm8x4 normal,
#                       unorm8x4 colour (rgb display, a = emissive), unorm8x4 material
#                       (roughness, metallic, kind, param)
#   scene_indices.bin   u32 triangles
#   scene_meta.luau     atlas frames, walking colliders, pickable objects, animated parts
#
# Run inside Blender (MCP execute_blender_code):
#   exec(open(os.path.expanduser("~/chiller-room/tools/export_scene.py")).read()); print(export_scene())
# export_scene(out_dir) writes somewhere else for a dry run.
#
# Conventions the scene relies on:
#   - collections Labels, Plant, Piping, Chiller HiFi, Room Shell (drawn in that order)
#   - materials carry web_rgb (0-1 display), web_emit, web_rough, web_metal, web_kind, web_param
#     (kind: 0 generic 1 floor 2 ceiling 3 wall 4 flowing pipe 5 glass 6 blinking 7 concrete
#      8 screen 9 label 10 animated)
#   - objects carry "pick" (inspect id), optional "flow" (pipe direction) and
#     "anim_pivot"/"anim_axis" (handwheels)
#   - every object in Labels, plus the screens and gauge faces, is an atlas frame
#   - Blender (x, y, z) -> room (x, z, -y)

import bpy, bmesh, struct, os, json
from mathutils import Vector

COLS = ("Labels", "Plant", "Piping", "Chiller HiFi", "Walkways", "Room Shell", "Yard")
KIND_ANIM = 10
SCREENS_FIXED = ["Control Panel Screen", "VFD Screen 1", "VFD Screen 2", "Refrigerant Monitor Screen"]
SKIP_SHELL = {"Floor", "Walls", "Ceiling", "Skirting and Corner Guards", "Chiller Pad", "Floor Stripe",
              "Floor Markings", "Floor Markings Black", "Tube Pull Zone"}


def collection(name):
    c = bpy.data.collections.get(name)
    if c is None:
        c = bpy.data.collections.new(name)
        bpy.context.scene.collection.children.link(c)
    return c


def room(p):
    return (p.x, p.z, -p.y)


def is_screen(name):
    return name in SCREENS_FIXED or ("Screen" in name.split() and not name.startswith("Label"))


def gauge_frame(ob):
    vs = [ob.matrix_world @ v.co for v in ob.data.vertices]
    zmid = (min(v.z for v in vs) + max(v.z for v in vs)) / 2
    top = [v for v in vs if v.z >= zmid - 1e-4] if ob.name.endswith("Gauge Faces") else vs
    lo = Vector((min(v.x for v in top), min(v.y for v in top), min(v.z for v in top)))
    hi = Vector((max(v.x for v in top), max(v.y for v in top), max(v.z for v in top)))
    if hi.x - lo.x < hi.y - lo.y:
        if ob.get("faces_plus_x"):
            return Vector((lo.x, lo.y, lo.z)), Vector((0, hi.y - lo.y, 0)), Vector((0, 0, hi.z - lo.z))
        return Vector((hi.x, hi.y, lo.z)), Vector((0, -(hi.y - lo.y), 0)), Vector((0, 0, hi.z - lo.z))
    return Vector((lo.x, hi.y, lo.z)), Vector((hi.x - lo.x, 0, 0)), Vector((0, 0, hi.z - lo.z))


def frame_of(ob):
    if ob.name.endswith("Gauge Faces") or ob.name.endswith("Gauge Face"):
        return gauge_frame(ob)
    if "frame_origin" in ob:   # explicit frame (a screen inset in a bezel)
        return Vector(ob["frame_origin"]), Vector(ob["frame_u"]), Vector(ob["frame_v"])
    vs = [ob.matrix_world @ v.co for v in ob.data.vertices]
    return vs[0], vs[1] - vs[0], vs[3] - vs[0]


def atlas_objects():
    names = [n for n in SCREENS_FIXED if bpy.data.objects.get(n)]
    names += sorted(o.name for o in bpy.data.objects if is_screen(o.name) and o.name not in names and not o.hide_get())
    gauges = sorted(o.name for o in bpy.data.objects
                    if (o.name.endswith("Gauge Faces") or o.name.endswith("Gauge Face")) and not o.hide_get())
    labels = sorted(o.name for o in collection("Labels").objects if not o.hide_get())
    return [n for n in names if n not in gauges] + labels + gauges


def island_colliders():
    """Footprints of every connected piece below head height (room coords), merged where they touch."""
    dg = bpy.context.evaluated_depsgraph_get()
    boxes = []
    for cname in ("Plant", "Piping", "Chiller HiFi"):
        for ob in collection(cname).objects:
            if ob.hide_get() or ob.type not in ("MESH", "CURVE") or ob.get("no_collide"):
                continue
            ev = ob.evaluated_get(dg); me = ev.to_mesh()
            bm = bmesh.new(); bm.from_mesh(me); seen = set()
            bm.faces.ensure_lookup_table()
            for f in bm.faces:
                if f.index in seen:
                    continue
                stack = [f]; seen.add(f.index); lo = [1e9, 1e9]; hi = [-1e9, -1e9]; tall = [1e9, -1e9]
                while stack:
                    g = stack.pop()
                    for v in g.verts:
                        p = ob.matrix_world @ v.co
                        if 0.03 < p.z < 1.9:
                            lo[0] = min(lo[0], p.x); lo[1] = min(lo[1], p.y); hi[0] = max(hi[0], p.x); hi[1] = max(hi[1], p.y)
                            tall[0] = min(tall[0], p.z); tall[1] = max(tall[1], p.z)
                        for h in v.link_faces:
                            if h.index not in seen:
                                seen.add(h.index); stack.append(h)
                if hi[0] > lo[0] and tall[1] - tall[0] > 0.04:
                    boxes.append([lo[0], lo[1], hi[0], hi[1]])
            bm.free(); ev.to_mesh_clear()
    merged = True
    while merged:
        merged = False; out = []
        while boxes:
            a = boxes.pop(); i = 0
            while i < len(boxes):
                b = boxes[i]
                if a[0] <= b[2] + 0.05 and b[0] <= a[2] + 0.05 and a[1] <= b[3] + 0.05 and b[1] <= a[3] + 0.05 and \
                   (max(a[2], b[2]) - min(a[0], b[0])) * (max(a[3], b[3]) - min(a[1], b[1])) <= \
                   1.3 * ((a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1])) + 0.02:
                    a = [min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3])]; boxes.pop(i); merged = True
                else:
                    i += 1
            out.append(a)
        boxes = out
    boxes = [(b[0], -b[3], b[2], -b[1]) for b in boxes]
    # Shell furniture (posts, cabinets on walls) that stands in the walkway.
    for ob in collection("Room Shell").objects:
        if ob.hide_get() or ob.type != "MESH" or ob.name in SKIP_SHELL or ob.get("no_collide"):
            continue
        vs = [ob.matrix_world @ v.co for v in ob.data.vertices]
        low = [v for v in vs if 0.03 < v.z < 1.9]
        if len(low) < 3:
            continue
        x0, x1 = min(v.x for v in low), max(v.x for v in low); y0, y1 = min(v.y for v in low), max(v.y for v in low)
        if (x1 - x0) > 0.02 and (y1 - y0) > 0.02 and (x1 - x0) * (y1 - y0) < 4.0:
            boxes.append((x0, -y1, x1, -y0))
    return boxes


def export_scene(out_dir=None):
    out = os.path.expanduser(out_dir or "~/chiller-room")
    os.makedirs(out, exist_ok=True)
    dg = bpy.context.evaluated_depsgraph_get()
    frames, frame_index = [], {}
    for name in atlas_objects():
        ob = bpy.data.objects.get(name)
        if ob is None or ob.hide_get():
            continue
        o, u, v = frame_of(ob)
        frame_index[name] = len(frames) + 1
        frames.append((room(o), room(u), room(v), name))
    anims, anim_index = [], {}
    for ob in sorted(bpy.data.objects, key=lambda o: o.name):
        if "anim_pivot" in ob and not ob.hide_get():
            anim_index[ob.name] = len(anims) + 1
            p = Vector(ob["anim_pivot"]); a = Vector(ob["anim_axis"])
            anims.append((room(p), room(a), ob.get("pick", "")))
    verts, index, tris = bytearray(), {}, bytearray()
    nv = nt = 0
    objects = []
    for cname in COLS:
        for ob in sorted(collection(cname).objects, key=lambda o: o.name):
            if ob.hide_get() or ob.type not in ("MESH", "CURVE"):
                continue
            ev = ob.evaluated_get(dg); me = ev.to_mesh()
            bm = bmesh.new(); bm.from_mesh(me); bmesh.ops.triangulate(bm, faces=bm.faces[:]); bm.to_mesh(me); bm.free()
            mw = ob.matrix_world; nm = mw.to_3x3().inverted().transposed(); cn = me.corner_normals
            first = nt; lo = [1e9] * 3; hi = [-1e9] * 3
            flow = ob.get("flow")
            fbits = 0
            if flow is not None:
                rd = (flow[0], flow[2], -flow[1])
                fbits = (1 if rd[0] > 0 else 0) | (2 if rd[1] > 0 else 0) | (4 if rd[2] > 0 else 0)
            for poly in me.polygons:
                m = ob.material_slots[poly.material_index].material if ob.material_slots else None
                rgb = m.get("web_rgb", (0.6, 0.6, 0.6)) if m else (0.6, 0.6, 0.6)
                emit = int(m.get("web_emit", 0)) if m else 0
                rough = float(m.get("web_rough", 0.5)) if m else 0.5
                metal = float(m.get("web_metal", 0.0)) if m else 0.0
                kind = int(m.get("web_kind", 0)) if m else 0
                param = int(m.get("web_param", 0)) if m else 0
                if ob.name in frame_index:
                    param = frame_index[ob.name]
                if kind == 4:
                    param = (param & 7) | (fbits << 3)
                if ob.name in anim_index:
                    kind, param = KIND_ANIM, anim_index[ob.name]
                col = tuple(max(0, min(255, round(c * 255))) for c in rgb) + (255 if emit else 0,)
                mt = (round(rough * 255), round(metal * 255), kind, param)
                tri = []
                for li in poly.loop_indices:
                    p = mw @ me.vertices[me.loops[li].vertex_index].co
                    n = (nm @ cn[li].vector).normalized()
                    P = tuple(round(c, 4) for c in room(p))
                    for i in range(3):
                        lo[i] = min(lo[i], P[i]); hi[i] = max(hi[i], P[i])
                    N = tuple(max(-127, min(127, round(c * 127))) for c in room(n))
                    k = (P, N, col, mt)
                    if k not in index:
                        index[k] = nv; nv += 1
                        verts += struct.pack("<3f4b4B4B", *P, *N, 0, *col, *mt)
                    tri.append(index[k])
                tris += struct.pack("<3I", tri[0], tri[2], tri[1]); nt += 1
            ev.to_mesh_clear()
            if nt > first:
                objects.append((ob.get("pick", ""), first, nt - first, lo, hi))
    colliders = island_colliders()
    open(os.path.join(out, "scene_vertices.bin"), "wb").write(verts)
    open(os.path.join(out, "scene_indices.bin"), "wb").write(tris)
    f4 = lambda t: "{ " + ", ".join(f"{c:.4f}" for c in t) + " }"
    L = ["--!nocheck", "-- GENERATED by tools/export_scene.py from chiller_hifi.blend. Do not edit.",
         "-- Room coordinates: x right, y up, z toward the door (Blender x, z, -y).", "",
         "export type Frame = { origin: { number }, u: { number }, v: { number }, name: string }",
         "export type Box = { x0: number, z0: number, x1: number, z1: number }",
         "export type Pickable = { pick: string, first: number, count: number, min: { number }, max: { number } }",
         "export type Anim = { pivot: { number }, axis: { number }, pick: string }", "",
         "local frames: { Frame } = {"]
    for o, u, v, name in frames:
        L.append(f'    {{ origin = {f4(o)}, u = {f4(u)}, v = {f4(v)}, name = "{name}" }},')
    L += ["}", "", "-- Footprints below head height, for walking collision.", "local colliders: { Box } = {"]
    for x0, z0, x1, z1 in colliders:
        L.append(f"    {{ x0 = {x0:.3f}, z0 = {z0:.3f}, x1 = {x1:.3f}, z1 = {z1:.3f} }},")
    L += ["}", "", "-- Every drawn object: its inspect id (\"\" = scenery, still blocks clicks), triangle range and bounds.",
          "local objects: { Pickable } = {"]
    for pick, first, count, lo, hi in objects:
        L.append(f'    {{ pick = "{pick}", first = {first}, count = {count}, min = {f4(lo)}, max = {f4(hi)} }},')
    L += ["}", "", "-- Animated parts (training valve handwheels, leak drops): pivot, axis, owning inspect id.", "local anims: { Anim } = {"]
    for p, a, pick in anims:
        L.append(f'    {{ pivot = {f4(p)}, axis = {f4(a)}, pick = "{pick}" }},')
    L += ["}", "", "return { frames = frames, colliders = colliders, objects = objects, anims = anims }", ""]
    open(os.path.join(out, "scene_meta.luau"), "w").write("\n".join(L))
    json.dump(colliders, open(os.path.join(out, "colliders.json"), "w"))
    return {"vertices": nv, "triangles": nt, "frames": len(frames), "objects": len(objects),
            "colliders": len(colliders), "anims": len(anims)}
