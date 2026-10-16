# Clerestory windows around the upper level: the outer walls get openings (sill 7.25 m, head 9.15 m),
# each with a reveal, an aluminium frame and centre mullion, and an inside sill. The glass is surface
# kind 11 (room.wgsl draws the landscape seen through it). Re-runnable. Run inside Blender:
#   exec(open(os.path.expanduser("~/chiller-room/tools/windows.py")).read()); print(windows())

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/walkways.py")).read())   # ROOF, web_mat, box, quad, new_obj...

X0, X1, Z0, Z1 = -10.0, X_END, -7.0, 7.0
SILL, HEAD = 7.25, 9.15
DEPTH = 0.3                      # reveal: from the inside wall face out to the glass
FRAME = 0.07                     # frame and mullion width


def openings():
    """(wall, a0, a1): wall is S/N (along x) or W/E (along z); a0..a1 the opening's extent along it."""
    out = []
    for k in range(16):
        c = -8.5 + 3.0 * k
        out.append(("S", c - 1.25, c + 1.25))
        if not (c - 1.25 < X_WALL + WALL_T + 0.1 and c + 1.25 > X_WALL - 0.1):   # the dividing wall meets N here
            out.append(("N", c - 1.25, c + 1.25))
    for c in (-5.25, -1.75, 1.75, 5.25):
        out.append(("W", c - 1.5, c + 1.5))
        out.append(("E", c - 1.5, c + 1.5))
    return out


# Each wall: its plane, which way is inward, and how an (along, height, out) triple maps to room x, y, z.
WALLS = {
    "S": dict(lo=X0, hi=X1, inward=Vector((0, 0, -1)), pt=lambda a, y, o: (a, y, Z1 + o)),
    "N": dict(lo=X0, hi=X1, inward=Vector((0, 0, 1)), pt=lambda a, y, o: (a, y, Z0 - o)),
    "W": dict(lo=Z0, hi=Z1, inward=Vector((1, 0, 0)), pt=lambda a, y, o: (X0 - o, y, a)),
    "E": dict(lo=Z0, hi=Z1, inward=Vector((-1, 0, 0)), pt=lambda a, y, o: (X1 + o, y, a)),
}


def rn(f):
    """A bmesh face's normal in room coordinates."""
    n = f.normal
    return Vector((n.x, n.z, -n.y))


def face(bm, pts, want):
    """A quad of room points, flipped if needed so its normal faces `want` (room coordinates)."""
    vs = [bm.verts.new(B(*p)) for p in pts]
    f = bm.faces.new(vs)
    f.normal_update()
    if rn(f).dot(want) < 0:
        f.normal_flip()
    return f


def rect(bm, w, a0, a1, y0, y1, o=0.0, want=None):
    P = WALLS[w]["pt"]
    face(bm, [P(a0, y0, o), P(a1, y0, o), P(a1, y1, o), P(a0, y1, o)], want or WALLS[w]["inward"])


def walls_with_windows():
    bm = bmesh.new()
    ops = openings()
    for w, d in WALLS.items():
        lo, hi = d["lo"], d["hi"]
        rect(bm, w, lo, hi, 0.0, SILL)
        rect(bm, w, lo, hi, HEAD, ROOF)
        cuts = sorted((a0, a1) for ww, a0, a1 in ops if ww == w)
        a = lo
        for a0, a1 in cuts:
            rect(bm, w, a, a0, SILL, HEAD)
            a = a1
        rect(bm, w, a, hi, SILL, HEAD)
    # The dividing wall, as walls() builds it.
    a, b = X_WALL, X_WALL + WALL_T
    face(bm, [(a, 0, Z0), (a, ROOF, Z0), (a, ROOF, OPEN_Z0), (a, 0, OPEN_Z0)], Vector((-1, 0, 0)))
    face(bm, [(b, 0, OPEN_Z0), (b, ROOF, OPEN_Z0), (b, ROOF, Z0), (b, 0, Z0)], Vector((1, 0, 0)))
    face(bm, [(b, 0, OPEN_Z0), (a, 0, OPEN_Z0), (a, ROOF, OPEN_Z0), (b, ROOF, OPEN_Z0)], Vector((0, 0, 1)))
    ob = bpy.data.objects["Walls"]
    ob.matrix_world = Matrix.Identity(4)
    bm.to_mesh(ob.data); bm.free(); ob.data.update()


def windows():
    walls_with_windows()
    reveal_m = web_mat("WN Reveal", (196, 198, 196), 0.8, 0.0)
    frame_m = web_mat("WN Aluminium", (58, 62, 68), 0.35, 0.7)
    glass_m = web_mat("WN Glass View", (200, 220, 235), 0.05, 0.0, kind=11)
    rv = bmesh.new(); fr = bmesh.new(); gl = bmesh.new()
    for w, a0, a1 in openings():
        d = WALLS[w]; P = d["pt"]; inn = d["inward"]
        along = P(1, 0, 0); base = P(0, 0, 0)
        ax = Vector(along) - Vector(base)   # room direction of increasing "along"
        up = Vector((0, 1, 0))
        # Reveal: four faces from the wall face out to the glass, facing into the opening.
        face(rv, [P(a0, SILL, 0), P(a0, HEAD, 0), P(a0, HEAD, DEPTH), P(a0, SILL, DEPTH)], ax)
        face(rv, [P(a1, SILL, 0), P(a1, HEAD, 0), P(a1, HEAD, DEPTH), P(a1, SILL, DEPTH)], -ax)
        face(rv, [P(a0, SILL, 0), P(a1, SILL, 0), P(a1, SILL, DEPTH), P(a0, SILL, DEPTH)], up)
        face(rv, [P(a0, HEAD, 0), P(a1, HEAD, 0), P(a1, HEAD, DEPTH), P(a0, HEAD, DEPTH)], -up)
        # Inside sill: a ledge proud of the wall.
        lo, hi = P(a0 - 0.05, SILL - 0.05, -0.07), P(a1 + 0.05, SILL, DEPTH - 0.02)
        box(rv, min(lo[0], hi[0]), max(lo[0], hi[0]), lo[1], hi[1], min(lo[2], hi[2]), max(lo[2], hi[2]))
        # Glass at the outer face, facing in.
        rect(gl, w, a0, a1, SILL, HEAD, o=DEPTH)
        # Frame: perimeter and a centre mullion, just inside the glass.
        fo0, fo1 = DEPTH - 0.08, DEPTH - 0.01
        mid = (a0 + a1) / 2
        for (b0, b1, y0, y1) in ((a0, a0 + FRAME, SILL, HEAD), (a1 - FRAME, a1, SILL, HEAD),
                                 (a0, a1, SILL, SILL + FRAME), (a0, a1, HEAD - FRAME, HEAD),
                                 (mid - FRAME / 2, mid + FRAME / 2, SILL, HEAD)):
            p, q = P(b0, y0, fo0), P(b1, y1, fo1)
            box(fr, min(p[0], q[0]), max(p[0], q[0]), y0, y1, min(p[2], q[2]), max(p[2], q[2]))
    props = {"no_collide": True, "pick": "pass"}
    new_obj("Window Reveals", rv, reveal_m, "Room Shell", smooth=False, props=props)
    new_obj("Window Frames", fr, frame_m, "Room Shell", smooth=False, props=props)
    new_obj("Window Glass", gl, glass_m, "Room Shell", smooth=False, props=props)
    return f"{len(openings())} windows"
