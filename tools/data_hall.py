# The data hall north of the plant, and the chilled water pipe bridge between them. Outdoor surfaces
# are kind 12 (room.wgsl outdoorSurface): params 0 painted/metal, 2 concrete, 4 metal wall panels,
# 5 louvre, 6 roll-up door. Collection "Yard" (exported). Re-runnable. Run inside Blender:
#   exec(open(os.path.expanduser("~/chiller-room/tools/data_hall.py")).read()); print(data_hall())

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/cooling_towers.py")).read())   # out_mat, box, cyl, quad, rails_along, new_obj...

DX0, DX1 = -18.0, 42.0          # data hall facade along x
DZF, DZB = -38.0, -78.0         # front (south) face, back face
DH = 15.0                       # roof; the parapet and coping go a little higher
PX = (6.75, 8.25)               # pipe bridge: CHWS and CHWR centrelines (x), between the tray hangers inside
PY, PR = 5.3, 0.375             # centreline height, insulated jacket radius
BX0, BX1 = 5.75, 9.25           # bridge columns / truss planes
ROAD = (-25.0, -14.0)           # service road (z), drawn in room.wgsl's ground
TRUSS = (-26.5, -13.5)          # the truss spans the road between these bents
BENTS = (-9.5, -13.5, -26.5, -32.0, -36.2)


def front_quad(bm, x0, x1, y0, y1, z):
    """A quad in a plane facing south (+z)."""
    quad(bm, [(x0, y0, z), (x1, y0, z), (x1, y1, z), (x0, y1, z)])


def data_hall():
    panel = out_mat("DH Wall Panel", (222, 225, 228), 0.5, 0.15, 4)
    plinth = out_mat("YD Concrete", (168, 166, 160), 0.9, 0.0, 2)
    accent = out_mat("DH Accent", (52, 60, 72), 0.4, 0.3, 0)
    louvre = out_mat("DH Louvre", (120, 126, 130), 0.5, 0.5, 5)
    rollup = out_mat("DH Roll-Up", (176, 182, 186), 0.45, 0.5, 6)
    door = out_mat("DH Door", (70, 78, 88), 0.5, 0.3, 0)
    trim = out_mat("DH Trim", (90, 96, 104), 0.45, 0.6, 0)
    rtu = out_mat("DH Rooftop Units", (196, 198, 196), 0.5, 0.3, 1)
    lamp = out_mat("DH Wall Lights", (60, 64, 70), 0.4, 0.5, 0)
    jacket = out_mat("PB Aluminium Jacket", (198, 202, 206), 0.35, 0.8, 0)
    steel = out_mat("PB Steel", (120, 126, 132), 0.45, 0.6, 0)
    bumper = out_mat("DH Dock Bumper", (24, 24, 26), 0.8, 0.0, 0)

    wl, pl, ac, lv, ru, dr, tr, rt, lp, jk, sl, bp, cn = (bmesh.new() for _ in range(13))

    # The building: walls (the front one carries the panels), roof, parapet coping, plinth, accent band.
    zf = DZF
    box(wl, DX0, DX1, 0.0, DH + 0.9, DZB, zf)
    box(tr, DX0 - 0.08, DX1 + 0.08, DH + 0.9, DH + 1.0, zf - 0.35, zf + 0.08)
    box(pl, DX0 - 0.05, DX1 + 0.05, 0.0, 1.2, zf - 0.2, zf + 0.05)
    box(ac, DX0 - 0.03, DX1 + 0.03, 12.6, 13.3, zf - 0.1, zf + 0.03)
    for x in (DX0 - 0.03, DX1 - 0.27):
        box(ac, x, x + 0.3, 1.2, DH + 0.9, zf - 0.3, zf + 0.03)   # corner trims
    # Louvre banks in a frame on the face of the wall.
    for x0 in (-12.0, 22.0, 29.0):
        x1 = x0 + 6.0
        front_quad(lv, x0, x1, 1.8, 6.2, zf + 0.02)
        for a, b, c, d in ((x0 - 0.1, x1 + 0.1, 1.7, 1.8), (x0 - 0.1, x1 + 0.1, 6.2, 6.3), (x0 - 0.1, x0, 1.7, 6.3), (x1, x1 + 0.1, 1.7, 6.3)):
            box(tr, a, b, c, d, zf, zf + 0.1)
        for x in (x0 + 2.0, x0 + 4.0):
            box(tr, x - 0.04, x + 0.04, 1.8, 6.2, zf, zf + 0.08)   # mullions
    # Personnel doors with canopies.
    for x in (2.0, 16.5):
        box(dr, x, x + 1.0, 0.0, 2.2, zf + 0.05, zf + 0.08)   # in front of the plinth
        for a, b, c, d in ((x - 0.06, x, 0.0, 2.28), (x + 1.0, x + 1.06, 0.0, 2.28), (x - 0.06, x + 1.06, 2.2, 2.28)):
            box(tr, a, b, c, d, zf + 0.05, zf + 0.11)
        box(tr, x + 0.8, x + 0.85, 1.0, 1.1, zf + 0.08, zf + 0.14)   # lever
        box(tr, x - 0.5, x + 1.5, 2.7, 2.8, zf, zf + 1.2)
        box(lp, x + 0.35, x + 0.65, 3.0, 3.25, zf, zf + 0.18)
    # Loading dock: roll-up door, bumpers, canopy, a dock light.
    box(ru, 36.5, 40.5, 1.2, 5.7, zf, zf + 0.04)
    for a, b in ((36.35, 36.5), (40.5, 40.65)):
        box(tr, a, b, 1.2, 5.9, zf, zf + 0.08)   # jambs
    box(tr, 36.5, 40.5, 5.7, 6.2, zf, zf + 0.25)   # coil box
    box(pl, 35.5, 41.5, 0.0, 1.2, zf, zf + 0.6)    # dock edge
    for x in (36.2, 40.6):
        box(bp, x - 0.15, x + 0.15, 0.4, 1.1, zf + 0.6, zf + 0.75)
    box(tr, 35.5, 41.5, 6.6, 6.75, zf, zf + 3.0)
    # Wall lights and downspouts.
    for x in (-15.0, -5.0, 5.0, 12.0, 25.0, 35.0):
        box(lp, x - 0.18, x + 0.18, 7.0, 7.3, zf, zf + 0.22)
    for x in (-14.5, 21.55, 35.3):
        box(tr, x - 0.06, x + 0.06, 0.1, DH + 0.7, zf, zf + 0.12)
    # Rooftop units just behind the parapet.
    for x0 in (-6.0, 12.0, 28.0):
        box(rt, x0, x0 + 4.5, DH, DH + 2.6, zf - 6.0, zf - 2.5)
        cyl(rt, (x0 + 1.2, DH + 2.6, zf - 4.2), (x0 + 1.2, DH + 2.8, zf - 4.2), 0.6, seg=20, caps=True)
        cyl(rt, (x0 + 3.3, DH + 2.6, zf - 4.2), (x0 + 3.3, DH + 2.8, zf - 4.2), 0.6, seg=20, caps=True)

    # The pipe bridge: two jacketed lines from the plant wall to the data hall, with bands every 1.5 m.
    z0, z1 = -7.15, zf + 0.02
    for x in PX:
        cyl(jk, (x, PY, z0), (x, PY, z1), PR, seg=28)
        z = z0 - 0.75
        while z > z1 + 0.3:
            cyl(jk, (x, PY, z), (x, PY, z - 0.03), PR + 0.008, seg=28, caps=True)
            z -= 1.5
        for zz in (-7.15, zf + 0.02):   # flashing collars at both walls
            cyl(jk, (x, PY, zz), (x, PY, zz + (0.12 if zz < -20 else -0.12)), PR + 0.12, seg=28, caps=True)
    # Bents: two columns on pedestals, a crossbeam under the pipes, knee braces; pipe shoes.
    for z in BENTS:
        for x in (BX0, BX1):
            box(cn, x - 0.35, x + 0.35, 0.0, 0.45, z - 0.35, z + 0.35)
            box(sl, x - 0.15, x + 0.15, 0.45, PY - PR - 0.15, z - 0.12, z + 0.12)
        box(sl, BX0 - 0.2, BX1 + 0.2, PY - PR - 0.3, PY - PR - 0.15, z - 0.12, z + 0.12)
        for x, s in ((BX0, 1), (BX1, -1)):
            cyl(sl, (x + s * 0.1, PY - PR - 1.3, z), (x + s * 0.9, PY - PR - 0.3, z), 0.05, seg=6)
        for x in PX:
            box(sl, x - 0.12, x + 0.12, PY - PR - 0.15, PY - PR + 0.05, z - 0.2, z + 0.2)
    # The truss over the road: two side trusses, floor beams at each panel point, top bracing.
    ta, tb = TRUSS
    n = 5
    yb, yt = PY - PR - 0.3, PY + PR + 1.2
    for x in (BX0, BX1):
        for y in (yb, yt):
            box(sl, x - 0.1, x + 0.1, y, y + 0.15, ta, tb)
        for k in range(n + 1):
            z = ta + (tb - ta) * k / n
            box(sl, x - 0.08, x + 0.08, yb, yt + 0.15, z - 0.08, z + 0.08)
            if k < n:
                zn = ta + (tb - ta) * (k + 1) / n
                if k < n / 2:
                    cyl(sl, (x, yb + 0.1, z), (x, yt + 0.05, zn), 0.06, seg=6)
                else:
                    cyl(sl, (x, yt + 0.05, z), (x, yb + 0.1, zn), 0.06, seg=6)
    for k in range(n + 1):
        z = ta + (tb - ta) * k / n
        box(sl, BX0, BX1, yb, yb + 0.15, z - 0.08, z + 0.08)
        box(sl, BX0, BX1, yt, yt + 0.12, z - 0.06, z + 0.06)
        for x in PX:
            box(sl, x - 0.12, x + 0.12, yb + 0.15, PY - PR + 0.05, z - 0.2, z + 0.2)
    for k in range(n):
        za, zb = ta + (tb - ta) * k / n, ta + (tb - ta) * (k + 1) / n
        cyl(sl, (BX0, yt + 0.1, za), (BX1, yt + 0.1, zb), 0.04, seg=6)
        cyl(sl, (BX1, yt + 0.1, za), (BX0, yt + 0.1, zb), 0.04, seg=6)
    # Longitudinal struts tying the bents together off the truss.
    for za, zb in ((-9.5, -13.5), (-26.5, -32.0), (-32.0, -36.2)):
        for x in (BX0, BX1):
            box(sl, x - 0.08, x + 0.08, PY - PR - 0.3, PY - PR - 0.18, zb, za)

    props = {"no_collide": True, "pick": "pass"}
    for name, bm_, m in (("Data Hall Walls", wl, panel), ("Data Hall Plinth and Dock", pl, plinth), ("Data Hall Accent Band", ac, accent),
                         ("Data Hall Louvres", lv, louvre), ("Data Hall Roll-Up Door", ru, rollup), ("Data Hall Doors", dr, door),
                         ("Data Hall Trim", tr, trim), ("Data Hall Rooftop Units", rt, rtu), ("Data Hall Lights", lp, lamp),
                         ("Pipe Bridge Jackets", jk, jacket), ("Pipe Bridge Steel", sl, steel), ("Data Hall Dock Bumpers", bp, bumper),
                         ("Pipe Bridge Pedestals", cn, plinth)):
        new_obj(name, bm_, m, YARD, smooth=name == "Pipe Bridge Jackets", props=props)
    # The sign: a lit panel high on the facade, facing south.
    bm = bmesh.new()
    sx0, sx1, sy0, sy1, sz = 9.0, 21.0, 9.4, 11.4, zf + 0.06
    bm.faces.new([bm.verts.new(B(*p)) for p in ((sx0, sy0, sz), (sx1, sy0, sz), (sx1, sy1, sz), (sx0, sy1, sz))])
    new_obj("Label Data Hall Sign", bm, bpy.data.materials["LB Label Lit"], "Labels", smooth=False, props={"pick": "pass"})
    bm = bmesh.new()
    box(bm, sx0 - 0.1, sx1 + 0.1, sy0 - 0.1, sy1 + 0.1, zf, zf + 0.05)
    new_obj("Data Hall Sign Box", bm, accent, YARD, smooth=False, props=props)
    return "data hall and pipe bridge built"
