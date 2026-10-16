# Raises the roof to 10 m, opens the plant room into the chiller hall, and adds the upper-level
# walkways (south walkway, two bridges, a stair). Run inside Blender after expand_plant.py:
#   exec(open(os.path.expanduser("~/chiller-room/tools/walkways.py")).read()); print(walkways())
# The walkable surfaces here must match WALK in main.luau.

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/expand_plant.py")).read())   # helpers: B, box, cyl, quad, new_obj, keep_faces...

ROOF = 10.0
OLD_ROOF = 6.0
DECK = 6.0                       # walkway deck height (top of grating)
SOUTH = (-9.4, 26.8, 5.6, 6.9)   # x0, x1, z0, z1
BRIDGES = [(4.65, 5.85), (20.15, 21.35)]   # x0, x1 (each runs z -6.9 .. 5.6)
BRIDGE_Z0 = -6.9
STAIR = (26.8, 35.8, 5.6, 6.9)   # top at x0 (deck height), bottom at x1 (floor)
OPEN_Z0 = 0.0                    # the dividing wall now stops here; south of it is open to the roof


def walkways_collection():
    c = bpy.data.collections.get("Walkways")
    if c is None:
        c = bpy.data.collections.new("Walkways")
        bpy.context.scene.collection.children.link(c)
    return c


def web_mat(name, rgb, rough, metal, kind=0):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*[(c / 255) ** 2.2 for c in rgb], 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    m["web_rgb"] = [c / 255 for c in rgb]; m["web_emit"] = 0; m["web_rough"] = rough; m["web_metal"] = metal
    m["web_kind"] = kind; m["web_param"] = 0
    return m


def raise_roof():
    """Everything that touched the old 6 m ceiling now reaches the 10 m roof; roof-mounted things move up."""
    move_all = {"Ceiling", "Steel Beams", "Sprinkler Heads", "Sprinkler Hangers", "Sprinkler Escutcheons",
                "Troffer Frames", "Troffer Lenses"}
    for ob in bpy.data.objects:
        if ob.type != "MESH" or ob.name == "Walls":
            continue
        base = ob.name.split(" Bay ")[0]
        whole = base in move_all
        fire = base == "Fire Sprinkler Piping"
        M = ob.matrix_world; inv = M.inverted()
        changed = False
        for v in ob.data.vertices:
            w = M @ v.co
            y = w.z
            if whole:
                ny = y + (ROOF - OLD_ROOF) - (0.0 if base in ("Ceiling", "Steel Beams") else 0.0)
                if base.startswith("Troffer"):
                    ny = y + (ROOF - 0.06 - 4.5)
            elif fire and y > 4.9:
                ny = y + (ROOF - OLD_ROOF)
            elif y >= OLD_ROOF - 0.05:
                ny = min(y + (ROOF - OLD_ROOF), ROOF)
            else:
                continue
            w.z = ny; v.co = inv @ w; changed = True
        if changed:
            ob.data.update()


def walls():
    """The building box at 10 m, and the dividing wall only north of z = 0 (behind the MCC)."""
    bm = bmesh.new()
    x0, x1, z0, z1, H = -10.0, X_END, -7.0, 7.0, ROOF
    quad(bm, [(x0, 0, z1), (x0, H, z1), (x0, H, z0), (x0, 0, z0)])
    quad(bm, [(x1, 0, z0), (x1, H, z0), (x1, H, z1), (x1, 0, z1)])
    quad(bm, [(x0, 0, z0), (x0, H, z0), (x1, H, z0), (x1, 0, z0)])
    quad(bm, [(x1, 0, z1), (x1, H, z1), (x0, H, z1), (x0, 0, z1)])
    a, b = X_WALL, X_WALL + WALL_T
    quad(bm, [(a, 0, z0), (a, H, z0), (a, H, OPEN_Z0), (a, 0, OPEN_Z0)])
    quad(bm, [(b, 0, OPEN_Z0), (b, H, OPEN_Z0), (b, H, z0), (b, 0, z0)])
    quad(bm, [(b, 0, OPEN_Z0), (a, 0, OPEN_Z0), (a, H, OPEN_Z0), (b, H, OPEN_Z0)])   # the wall's end
    want = {}
    for f in bm.faces:
        c = f.calc_center_median(); rc = Vector((c.x, c.z, -c.y))
        if abs(rc.x - x0) < 1e-3: d = Vector((1, 0, 0))
        elif abs(rc.x - x1) < 1e-3: d = Vector((-1, 0, 0))
        elif abs(rc.z - z0) < 1e-3: d = Vector((0, 0, 1))
        elif abs(rc.z - z1) < 1e-3: d = Vector((0, 0, -1))
        elif abs(rc.x - a) < 1e-3: d = Vector((-1, 0, 0))
        elif abs(rc.x - b) < 1e-3: d = Vector((1, 0, 0))
        else: d = Vector((0, 0, 1))    # the end face looks south, into the opening
        f.normal_update()
        n = f.normal; rn = Vector((n.x, n.z, -n.y))
        if rn.dot(d) < 0:
            f.normal_flip()
    ob = bpy.data.objects["Walls"]
    ob.matrix_world = Matrix.Identity(4)
    bm.to_mesh(ob.data); bm.free(); ob.data.update()
    # Skirting where the wall used to be.
    keep_faces(bpy.data.objects["Skirting and Corner Guards"], lambda x, y, z: not (x > 9.5 and z > OPEN_Z0 - 0.05))
    keep_faces(bpy.data.objects["Bay Skirting"], lambda x, y, z: not (10.2 < x < 10.4 and z > OPEN_Z0 - 0.05))
    # A steel column marks the end of the dividing wall, carrying a roof beam across the opening.
    steel = bpy.data.objects["Steel Beams"].material_slots[0].material
    bm = bmesh.new()
    box(bm, X_WALL, X_WALL + WALL_T, 0, ROOF, OPEN_Z0, OPEN_Z0 + 0.35)
    box(bm, X_WALL - 0.05, X_WALL + WALL_T + 0.05, ROOF - 0.6, ROOF, OPEN_Z0, 7.0)
    new_obj("Opening Column and Beam", bm, steel, "Room Shell", smooth=False)


def rails_along(bm, pts, h, post_every=1.5):
    """Handrail (top and mid rail) along a polyline of room points at walkway height, with posts."""
    for (ax, ay, az), (bx, by, bz) in zip(pts, pts[1:]):
        for rh in (1.07, 0.55):
            cyl(bm, (ax, ay + rh, az), (bx, by + rh, bz), 0.022, seg=8)
        L = math.dist((ax, az), (bx, bz))
        n = max(1, round(L / post_every))
        for k in range(n + 1):
            t = k / n
            x, y, z = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t
            box(bm, x - 0.025, x + 0.025, y, y + 1.1, z - 0.025, z + 0.025)


def deck(bm_g, bm_s, x0, x1, z0, z1, along_x):
    """Grating (top at DECK), toe boards and the steel frame under it."""
    t = 0.04
    box(bm_g, x0, x1, DECK - t, DECK, z0, z1)
    # Frame: two edge channels.
    if along_x:
        box(bm_s, x0, x1, DECK - 0.22, DECK - t, z0, z0 + 0.08)
        box(bm_s, x0, x1, DECK - 0.22, DECK - t, z1 - 0.08, z1)
    else:
        box(bm_s, x0, x0 + 0.08, DECK - 0.22, DECK - t, z0, z1)
        box(bm_s, x1 - 0.08, x1, DECK - 0.22, DECK - t, z0, z1)


def build_walkways():
    c = walkways_collection()
    for ob in list(c.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    grate = web_mat("WK Grating", (92, 98, 106), 0.6, 0.7)
    steel = web_mat("WK Steel Yellow", (232, 178, 24), 0.45, 0.2)
    frame = web_mat("WK Steel Frame", (70, 76, 86), 0.5, 0.6)
    g = bmesh.new(); s = bmesh.new(); r = bmesh.new()
    x0, x1, z0, z1 = SOUTH
    deck(g, s, x0, x1, z0, z1, True)
    # Wall brackets every 3 m under the south walkway.
    x = x0 + 0.3
    while x < x1:
        box(s, x - 0.05, x + 0.05, DECK - 1.0, DECK - 0.22, z1 - 0.05, 7.0)
        # diagonal knee brace
        cyl(s, (x, DECK - 0.25, z0 + 0.1), (x, DECK - 1.2, 6.98), 0.03, seg=6)
        x += 3.0
    # Rails on the open (north) side, broken where the bridges join.
    segs = [x0]
    for bx0, bx1 in BRIDGES:
        segs += [bx0, bx1]
    segs.append(x1)
    for a, b in zip(segs[::2], segs[1::2]):
        rails_along(r, [(a, DECK, z0 + 0.03), (b, DECK, z0 + 0.03)], DECK)
    rails_along(r, [(x0 + 0.03, DECK, z0), (x0 + 0.03, DECK, z1)], DECK)
    box(g, x0, x1, DECK, DECK + 0.1, z0, z0 + 0.012)   # toe board
    for bx0, bx1 in BRIDGES:
        deck(g, s, bx0, bx1, BRIDGE_Z0, z0, False)
        rails_along(r, [(bx0 + 0.03, DECK, z0), (bx0 + 0.03, DECK, BRIDGE_Z0 + 0.03), (bx1 - 0.03, DECK, BRIDGE_Z0 + 0.03), (bx1 - 0.03, DECK, z0)], DECK)
        box(g, bx0, bx0 + 0.012, DECK, DECK + 0.1, BRIDGE_Z0, z0)
        box(g, bx1 - 0.012, bx1, DECK, DECK + 0.1, BRIDGE_Z0, z0)
        # Hung from the roof on rods every 3 m.
        z = BRIDGE_Z0 + 1.0
        while z < z0:
            for x in (bx0 + 0.04, bx1 - 0.04):
                cyl(s, (x, DECK - 0.2, z), (x, ROOF - 0.6, z), 0.016, seg=8)
            box(s, bx0, bx1, DECK - 0.3, DECK - 0.2, z - 0.05, z + 0.05)
            z += 3.0
    # The stair: from the walkway's east end down to the floor near the east wall.
    sx0, sx1, sz0, sz1 = STAIR
    rise = 0.18
    n = round(DECK / rise)
    run = (sx1 - sx0) / n
    for k in range(n):
        top = DECK - k * rise
        xa = sx0 + k * run
        box(g, xa, xa + run + 0.02, top - rise - 0.03, top - rise, sz0 + 0.05, sz1 - 0.05)
    for z in (sz0 + 0.02, sz1 - 0.02):
        p = [(sx0, DECK, z), (sx1, 0.0, z)]
        a, b = B(*p[0]), B(*p[1])
        cyl(s, (sx0, DECK - 0.15, z), (sx1, -0.1, z), 0.06, seg=6)
        rails_along(r, [(sx0, DECK, z), (sx1, 0.0, z)], DECK, post_every=1.8)
    # Stair supports from the floor.
    for xs in (29.8, 32.8):
        hh = DECK * (sx1 - xs) / (sx1 - sx0)
        for z in (sz0 + 0.1, sz1 - 0.1):
            box(s, xs - 0.06, xs + 0.06, 0, hh - 0.2, z - 0.06, z + 0.06)
    for name, bm_, m in (("Walkway Grating", g, grate), ("Walkway Frame", s, frame), ("Walkway Handrails", r, steel)):
        ob = new_obj(name, bm_, m, "Walkways", smooth=(name == "Walkway Handrails"))
        ob["no_collide"] = True
        ob["pick"] = "pass"   # clicks go through the rails and grating to the equipment beyond


def walkways():
    raise_roof()
    walls()
    build_walkways()
    return "done"


HP_X = 21.65     # the high-point vents rise beside the hall bridge (its east rail is at 21.32)
HP_TOP = 6.85    # hand height on the walkway


def add_hp_vents():
    """Automatic air vents at the headers' high point, reached from the hall bridge."""
    for n in [o.name for o in bpy.data.objects if o.name.startswith("HP Vent") or o.name == "Label Sign HP Vents"]:
        bpy.data.objects.remove(bpy.data.objects[n], do_unlink=True)
    brass = bpy.data.materials.get("CH Brass")
    black = bpy.data.materials.get("CH Black")
    for circ, z, hy, r, rx, vtop, fl in HEADERS:
        m = bpy.data.objects[PIPE_OBJ[circ]].material_slots[0].material
        bm = bmesh.new()
        cyl(bm, (HP_X, hy, z), (HP_X, HP_TOP - 0.28, z), 0.035, seg=12)   # stub up from the header
        cyl(bm, (HP_X - 0.06, hy, z), (HP_X + 0.06, hy, z), r + 0.03, seg=20)  # saddle on the header
        new_obj(f"HP Vent {circ} Stub", bm, m, "Piping", props={"pick": "vent:HP", "no_collide": True})
        bm = bmesh.new()
        cyl(bm, (HP_X, HP_TOP - 0.28, z), (HP_X, HP_TOP - 0.18, z), 0.05, seg=16)     # isolating ball valve
        cyl(bm, (HP_X, HP_TOP - 0.23, z), (HP_X + 0.12, HP_TOP - 0.23, z), 0.012, seg=8)  # its lever
        cyl(bm, (HP_X, HP_TOP - 0.18, z), (HP_X, HP_TOP - 0.03, z), 0.055, seg=20)    # the vent can
        cyl(bm, (HP_X, HP_TOP - 0.03, z), (HP_X, HP_TOP, z), 0.02, seg=10, caps=True)  # cap
        new_obj(f"HP Vent {circ} Vent", bm, brass, "Piping", props={"pick": "vent:HP", "no_collide": True})
    # A bracket tying the four stubs together at deck height.
    bm = bmesh.new()
    box(bm, HP_X - 0.03, HP_X + 0.03, DECK - 0.4, DECK - 0.34, -4.05, -2.35)
    new_obj("HP Vent Bracket", bm, black, "Piping", props={"pick": "vent:HP", "no_collide": True})
    # The sign on the bridge's east rail, facing back onto the bridge (west) so you read it there.
    bm = bmesh.new()
    x = BRIDGES[1][1] - 0.01
    vs = [bm.verts.new(B(x, y, zz)) for y, zz in ((6.38, -1.95), (6.38, -1.55), (6.86, -1.55), (6.86, -1.95))]
    f = bm.faces.new(vs)
    f.normal_update()
    if f.normal.x > 0:
        f.normal_flip()
    new_obj("Label Sign HP Vents", bm, bpy.data.materials["PL Label"], "Labels", smooth=False, props={"pick": "vent:HP"})
