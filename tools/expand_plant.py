# Phase 3: extends the plant room east into a chiller hall with CH-2 and CH-3.
# Run inside Blender on the phase-2 scene (build/pre-phase3/chiller_hifi.blend):
#   exec(open(os.path.expanduser("~/chiller-room/tools/expand_plant.py")).read()); print(expand())
# Room coordinates (x right, y up, z toward the door) are used throughout; B() converts to Blender.

import bpy, bmesh, math
from mathutils import Vector, Matrix

X_WALL = 10.0          # the old east wall, now the dividing wall
X_END = 38.0           # the new east wall
WALL_T = 0.3           # dividing wall thickness (x 10.0 .. 10.3)
OPEN_Z = (0.4, 5.6)    # the knock-through, along z
OPEN_TOP = 4.2
CHILLERS = {"CH-2": 16.0, "CH-3": 29.0}     # x offset of each copy of CH-1

# The four headers: circuit, riser z, header height, radius, CH-1 riser x, nozzle centre y, flow along x (+1 east).
# Each chiller's nozzle leaves its water box at x = -2.95 (CH-1), runs west to the riser and climbs
# through the isolation valve into the header overhead.
HEADERS = [
    ("CHWS", -3.95, 3.40, 0.21, -3.45, 1.18, 1),
    ("CHWR", -3.55, 4.30, 0.21, -3.95, 0.74, -1),
    ("CWS", -2.85, 3.40, 0.20, -3.45, 1.18, -1),
    ("CWR", -2.45, 4.30, 0.20, -3.45, 0.81, 1),
]
NOZZLE_X = -2.95
PIPE_OBJ = {"CHWS": "Chilled Water Supply", "CHWR": "Chilled Water Return", "CWS": "Condenser Water Supply", "CWR": "Condenser Water Return"}


def B(x, y, z):
    return Vector((x, -z, y))


def col(name):
    return bpy.data.collections[name]


def link(ob, cname):
    for c in list(ob.users_collection):
        c.objects.unlink(ob)
    col(cname).objects.link(ob)


def new_obj(name, bm, mat, cname, smooth=True, props=None):
    old = bpy.data.objects.get(name)
    if old is not None:
        bpy.data.objects.remove(old, do_unlink=True)
    me = bpy.data.meshes.new(name); bm.to_mesh(me); bm.free()
    for p in me.polygons:
        p.use_smooth = smooth
    ob = bpy.data.objects.new(name, me)
    col(cname).objects.link(ob)
    me.materials.append(mat)
    if smooth:
        me.set_sharp_from_angle(angle=math.radians(40))
    for k, v in (props or {}).items():
        ob[k] = v
    return ob


def box(bm, x0, x1, y0, y1, z0, z1):
    g = bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.transform(bm, matrix=Matrix.Translation(B((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)) @
                        Matrix.Diagonal((x1 - x0, z1 - z0, y1 - y0, 1)), verts=g["verts"])


def cyl(bm, a, b, r, seg=24, caps=False):
    """A cylinder between room points a and b."""
    a, b = B(*a), B(*b)
    d = b - a
    g = bmesh.ops.create_cone(bm, cap_ends=caps, segments=seg, radius1=r, radius2=r, depth=d.length)
    rot = Vector((0, 0, 1)).rotation_difference(d.normalized()).to_matrix().to_4x4()
    bmesh.ops.transform(bm, matrix=Matrix.Translation((a + b) / 2) @ rot, verts=g["verts"])


def quad(bm, pts):
    vs = [bm.verts.new(B(*p)) for p in pts]
    bm.faces.new(vs)


def copy_obj(src, name, dx, cname=None, rename=None):
    old = bpy.data.objects.get(name)
    if old is not None:
        bpy.data.objects.remove(old, do_unlink=True)
    ob = src.copy()
    if src.data is not None:
        ob.data = src.data.copy()
    ob.name = name
    (col(cname) if cname else src.users_collection[0]).objects.link(ob)
    ob.matrix_world = Matrix.Translation(Vector((dx, 0, 0))) @ src.matrix_world
    for k in ("anim_pivot", "frame_origin"):
        if k in ob:
            p = list(ob[k]); p[0] += dx; ob[k] = p
    if rename and "pick" in ob:
        ob["pick"] = rename(ob["pick"])
    return ob


def keep_faces(ob, keep):
    """Deletes the faces whose room-space centre fails keep(x, y, z); applies the transform first."""
    me = ob.data
    bm = bmesh.new(); bm.from_mesh(me)
    M = ob.matrix_world
    dead = []
    for f in bm.faces:
        c = M @ f.calc_center_median()
        if not keep(c.x, c.z, -c.y):
            dead.append(f)
    bmesh.ops.delete(bm, geom=dead, context="FACES")
    bm.to_mesh(me); bm.free(); me.update()


def keep_islands(ob, keep):
    """Deletes connected pieces whose room-space centre fails keep(x, y, z)."""
    me = ob.data
    bm = bmesh.new(); bm.from_mesh(me)
    M = ob.matrix_world
    seen, dead = set(), []
    for f in bm.faces:
        if f.index in seen:
            continue
        stack, island = [f], []
        seen.add(f.index)
        while stack:
            g = stack.pop(); island.append(g)
            for e in g.edges:
                for h in e.link_faces:
                    if h.index not in seen:
                        seen.add(h.index); stack.append(h)
        c = Vector()
        n = 0
        for g in island:
            for v in g.verts:
                c += v.co; n += 1
        c = M @ (c / max(n, 1))
        if not keep(c.x, c.z, -c.y):
            dead += island
    bmesh.ops.delete(bm, geom=dead, context="FACES")
    bm.to_mesh(me); bm.free(); me.update()


def stretch_x(ob, x0, x1):
    """Maps the object's room-x extent onto x0..x1 (for long runs: trays, ducts)."""
    M = ob.matrix_world
    xs = [(M @ v.co).x for v in ob.data.vertices]
    lo, hi = min(xs), max(xs)
    inv = M.inverted()
    for v in ob.data.vertices:
        w = M @ v.co
        w.x = x0 + (w.x - lo) * (x1 - x0) / (hi - lo)
        v.co = inv @ w
    ob.data.update()


def mat(name):
    return bpy.data.materials[name]


# ---------------------------------------------------------------------------

def shell():
    # Walls: the big box, plus the dividing wall with its opening (both faces, jambs and head).
    wm = bpy.data.objects["Walls"].material_slots[0].material
    bm = bmesh.new()
    x0, x1, z0, z1, H = -10.0, X_END, -7.0, 7.0, 6.0
    quad(bm, [(x0, 0, z1), (x0, H, z1), (x0, H, z0), (x0, 0, z0)])          # west, faces +x
    quad(bm, [(x1, 0, z0), (x1, H, z0), (x1, H, z1), (x1, 0, z1)])          # east, faces -x
    quad(bm, [(x0, 0, z0), (x0, H, z0), (x1, H, z0), (x1, 0, z0)])          # north, faces +z
    quad(bm, [(x1, 0, z1), (x1, H, z1), (x0, H, z1), (x0, 0, z1)])          # south, faces -z
    a, b = X_WALL, X_WALL + WALL_T
    oz0, oz1 = OPEN_Z
    for (za, zb) in ((z0, oz0), (oz1, z1)):
        quad(bm, [(a, 0, za), (a, H, za), (a, H, zb), (a, 0, zb)])           # old-room face (faces -x)
        quad(bm, [(b, 0, zb), (b, H, zb), (b, H, za), (b, 0, za)])           # bay face (faces +x)
    quad(bm, [(a, OPEN_TOP, oz0), (a, H, oz0), (a, H, oz1), (a, OPEN_TOP, oz1)])
    quad(bm, [(b, OPEN_TOP, oz1), (b, H, oz1), (b, H, oz0), (b, OPEN_TOP, oz0)])
    quad(bm, [(a, 0, oz0), (b, 0, oz0), (b, OPEN_TOP, oz0), (a, OPEN_TOP, oz0)])   # jamb, faces +z
    quad(bm, [(b, 0, oz1), (a, 0, oz1), (a, OPEN_TOP, oz1), (b, OPEN_TOP, oz1)])   # jamb, faces -z
    quad(bm, [(a, OPEN_TOP, oz0), (b, OPEN_TOP, oz0), (b, OPEN_TOP, oz1), (a, OPEN_TOP, oz1)])  # head, faces down
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    for f in bm.faces:   # recalc can flip open shells: force every face toward the room interior
        c = f.calc_center_median()
        rc = Vector((c.x, c.z, -c.y))
        n = f.normal
        rn = Vector((n.x, n.z, -n.y))
        inward = Vector((0, 0, 0))
        if abs(rc.x - x0) < 1e-3: inward = Vector((1, 0, 0))
        elif abs(rc.x - x1) < 1e-3: inward = Vector((-1, 0, 0))
        elif abs(rc.z - z0) < 1e-3: inward = Vector((0, 0, 1))
        elif abs(rc.z - z1) < 1e-3: inward = Vector((0, 0, -1))
        elif abs(rc.x - a) < 1e-3: inward = Vector((-1, 0, 0))
        elif abs(rc.x - b) < 1e-3: inward = Vector((1, 0, 0))
        elif abs(rc.y - OPEN_TOP) < 1e-3: inward = Vector((0, -1, 0))
        elif abs(rc.z - oz0) < 1e-3: inward = Vector((0, 0, 1))
        elif abs(rc.z - oz1) < 1e-3: inward = Vector((0, 0, -1))
        if inward.length > 0 and rn.dot(inward) < 0:
            f.normal_flip()
    walls = bpy.data.objects["Walls"]
    me = walls.data
    walls.matrix_world = Matrix.Identity(4)
    bm.to_mesh(me); bm.free(); me.update()

    # Floor and ceiling grow east.
    for n, y in (("Floor", 0.0), ("Ceiling", 6.0)):
        ob = bpy.data.objects[n]
        M = ob.matrix_world; inv = M.inverted()
        for v in ob.data.vertices:
            w = M @ v.co
            if w.x > 9.99:
                w.x = X_END
            v.co = inv @ w
        ob.data.update()

    # Skirting: cut where the opening is, then add strips in the bay.
    sk = bpy.data.objects["Skirting and Corner Guards"]
    keep_faces(sk, lambda x, y, z: not (x > 9.5 and OPEN_Z[0] - 0.05 < z < OPEN_Z[1] + 0.05))
    bm = bmesh.new()
    t, h = 0.02, 0.15
    box(bm, b, X_END, 0, h, -7.0, -7.0 + t)
    box(bm, b, X_END, 0, h, 7.0 - t, 7.0)
    box(bm, X_END - t, X_END, 0, h, -7.0, 7.0)
    box(bm, b, b + t, 0, h, -7.0, oz0)
    box(bm, b, b + t, 0, h, oz1, 7.0)
    new_obj("Bay Skirting", bm, sk.material_slots[0].material, "Room Shell", smooth=False)

    # The louver moves to the new east wall; the refrigerant exhaust duct moves north, out of the headers' way.
    for n in ("Exhaust Louver Blades", "Exhaust Louver Frame"):
        ob = bpy.data.objects[n]
        ob.matrix_world = Matrix.Translation(Vector((X_END - X_WALL, 0, 0))) @ ob.matrix_world
    for n in ("Refrigerant Exhaust Duct", "Refrigerant Exhaust Grille"):
        ob = bpy.data.objects[n]
        ob.matrix_world = Matrix.Translation(B(0, 0, -1.7) - B(0, 0, 0)) @ ob.matrix_world

    # Overhead services repeat into the bay: lights, beams, sprinklers, troffers by the piece;
    # long runs (tray, duct) are copied and stretched.
    lo, hi = X_WALL + WALL_T + 0.2, X_END - 0.8
    for n in ("Light Fixtures", "Light Lenses", "Light Cables", "Steel Beams", "Sprinkler Heads", "Sprinkler Hangers",
              "Sprinkler Escutcheons", "Troffer Frames", "Troffer Lenses", "Supply Diffusers", "Duct Registers", "Duct Hangers"):
        src = bpy.data.objects.get(n)
        if src is None:
            continue
        for i, dx in enumerate((20.0, 30.0)):
            win = (lo, 30.0) if i == 0 else (30.0, hi)
            ob = copy_obj(src, f"{n} Bay {i + 1}", dx)
            keep_islands(ob, lambda x, y, z, w=win: w[0] <= x < w[1])
    for n in ("Cable Tray", "Tray Cables", "Tray Hangers", "Supply Duct"):
        src = bpy.data.objects[n]
        ob = copy_obj(src, f"{n} Bay", 0.0)
        stretch_x(ob, lo, hi)


def chiller_sets():
    def is_ch1(ob):
        p = str(ob.get("pick", ""))
        return p in ("chiller:CH-1", "panel:CH1-CP") or p.startswith("valve:CH1-C") and p.endswith("-IV") or p.startswith("gauge:CH1-")
    srcs = [o for o in bpy.data.objects if o.type in ("MESH", "CURVE") and is_ch1(o)]
    extra = ["Chiller Pad", "Floor Stripe", "Tube Pull Zone", "Label Floor Tube Pull", "Label Chiller Tag", "Label Nameplate"]
    srcs += [bpy.data.objects[n] for n in extra]
    for tag, dx in CHILLERS.items():
        num = tag[-1]
        ren = lambda p, num=num: p.replace("CH-1", "CH-" + num).replace("CH1-", "CH" + num + "-")
        for src in srcs:
            name = f"{tag} {src.name}" if not src.name.startswith("Label") else f"{src.name} {tag}"
            copy_obj(src, name, dx, rename=ren)


def headers():
    for circ, z, hy, r, rx, vtop, fl in HEADERS:
        src = bpy.data.objects[PIPE_OBJ[circ]]
        m = src.material_slots[0].material
        props = {"pick": "pipe:" + circ, "circuit": circ, "flow": [float(fl), 0.0, 0.0]}
        bm = bmesh.new()
        cyl(bm, (rx, hy, z), (X_END + 0.05, hy, z), r)
        new_obj(f"{circ} Header", bm, m, "Piping", props=props)
        # Each new chiller's nozzle stub and riser, through its isolation valve into the header.
        bm = bmesh.new()
        for tag, dx in CHILLERS.items():
            cyl(bm, (NOZZLE_X + dx + 0.02, vtop, z), (rx + dx - r * 0.7, vtop, z), r)
            g = bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=r)   # the elbow
            bmesh.ops.transform(bm, matrix=Matrix.Translation(B(rx + dx, vtop, z)), verts=g["verts"])
            cyl(bm, (rx + dx, vtop, z), (rx + dx, hy, z), r)
        up = 1.0 if circ in ("CHWS", "CWR") else -1.0
        new_obj(f"{circ} Bay Risers", bm, m, "Piping", props={"pick": "pipe:" + circ, "circuit": circ, "flow": [0.0, 0.0, up]})
    # Wall sleeves where the headers pass through, and hanger rods every 4 m.
    sleeve = bpy.data.materials.get("CH Galvanised")
    bm = bmesh.new()
    for circ, z, hy, r, rx, vtop, fl in HEADERS:
        cyl(bm, (X_WALL - 0.05, hy, z), (X_WALL + WALL_T + 0.05, hy, z), r + 0.04, caps=False)
        cyl(bm, (X_END - 0.12, hy, z), (X_END, hy, z), r + 0.04, caps=False)
        x = 0.0
        while x < X_END - 1:
            if not (X_WALL - 0.5 < x < X_WALL + WALL_T + 0.5):
                cyl(bm, (x, hy + r, z), (x, 6.0, z), 0.012, seg=8)
            x += 4.0
    new_obj("Header Sleeves and Hangers", bm, sleeve, "Piping", props={"pick": "support"})


def expand():
    shell()
    chiller_sets()
    headers()
    return "expanded"
