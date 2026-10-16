# The chilled water branches to Data Hall 01: off the CHWS header (x 6.75) and the CHWR header (x 8.25),
# north, up to 5.3 m and out through the north wall where the pipe bridge leaves (tools/data_hall.py).
# Each has an isolation valve, flanges, hangers, a wall escutcheon and a pipe marker. Re-runnable:
#   exec(open(os.path.expanduser("~/chiller-room/tools/dh_connection.py")).read()); print(dh_connection())

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/pumpout_hoist.py")).read())   # mat, sphere, label_quad, box, cyl...

R = 0.21                       # insulated, as the headers
ZUP = -5.0                     # where each branch turns up
YOUT = 5.3                     # and runs out through the wall (the bridge pipes' height)
BRANCHES = (
    # name, x, header centre y, header centre z, circuit, flow bits (+x 1, +y 2, +z 4), valve y, operator side
    ("CHWS", 6.75, 3.4, -3.95, 1, 2, 4.45, -1),   # supply: up and north (out to the data hall)
    ("CHWR", 8.25, 4.3, -3.55, 2, 4, 4.8, 1),     # return: south and down (back from it)
)


def dh_connection():
    dark = bpy.data.materials["CH Steel Dark"]
    red = bpy.data.materials["CH Valve Red"]
    steel = mat("SV Steel", (70, 74, 80), 0.5, 0.6)
    for name, x, hy, hz, circuit, bits, vy, side in BRANCHES:
        jacket = web_mat(f"PL Insulation Jacket DH {name}", (204, 207, 209), 0.4, 0.1, kind=4)
        jacket["web_param"] = circuit | (bits << 3)
        pp, fl, vb, op, hw, hg = (bmesh.new() for _ in range(6))
        pts = [(x, hy, hz), (x, hy, ZUP), (x, YOUT, ZUP), (x, YOUT, -6.98)]
        for a, b in zip(pts, pts[1:]):
            cyl(pp, a, b, R, seg=24)
        for p in pts[1:3]:
            sphere(pp, p, R, seg=24)   # elbows
        # Isolation butterfly valve on the riser: flanges, red body, gear operator and handwheel.
        for y in (vy - 0.13, vy + 0.13):
            cyl(fl, (x, y - 0.03, ZUP), (x, y + 0.03, ZUP), R + 0.09, seg=24, caps=True)
        cyl(vb, (x, vy - 0.1, ZUP), (x, vy + 0.1, ZUP), R + 0.05, seg=24, caps=True)
        ox = x + side * (R + 0.2)
        box(op, min(x, ox) - 0.06, max(x, ox) + 0.06, vy - 0.09, vy + 0.09, ZUP - 0.09, ZUP + 0.09)
        cyl(op, (ox, vy, ZUP), (ox, vy, ZUP + 0.22), 0.03, seg=8)
        cyl(hw, (ox, vy, ZUP + 0.22), (ox, vy, ZUP + 0.25), 0.2, seg=24, caps=True)
        # Flanges at the bends, the wall escutcheon, hangers to the roof steel.
        cyl(fl, (x, YOUT, -6.9), (x, YOUT, -6.99), R + 0.1, seg=24, caps=True)
        for z in (-5.55, -6.75):
            cyl(hg, (x, YOUT + R, z), (x, 9.55, z), 0.012, seg=6)
            cyl(hg, (x - R - 0.03, YOUT, z - 0.03), (x + R + 0.03, YOUT, z - 0.03), 0.02, seg=6)
            cyl(hg, (x - R - 0.03, YOUT, z + 0.03), (x + R + 0.03, YOUT, z + 0.03), 0.02, seg=6)
        pick = {"pick": f"pipe:{name}", "no_collide": True}
        new_obj(f"DH {name} Branch", pp, jacket, "Piping", smooth=True, props=pick)
        new_obj(f"DH {name} Flanges", fl, dark, "Piping", smooth=True, props=pick)
        new_obj(f"DH {name} Valve Body", vb, red, "Piping", smooth=True, props=pick)
        new_obj(f"DH {name} Gear Operator", op, dark, "Piping", smooth=False, props=pick)
        new_obj(f"DH {name} Handwheel", hw, red, "Piping", smooth=True, props=pick)
        new_obj(f"DH {name} Hangers", hg, steel, "Piping", smooth=False, props=pick)
        # Pipe markers: on the supply riser's south face; along the return's top run (east face).
        if name == "CHWS":
            z = ZUP + R + 0.006
            label_quad("Label Pipe DH CHWS", [(x - 0.14, 3.72, z), (x + 0.14, 3.72, z), (x + 0.14, 4.24, z), (x - 0.14, 4.24, z)], "pipe:CHWS")
        else:
            lx = x + R + 0.006
            label_quad("Label HPipe DH CHWR", [(lx, YOUT - 0.1, -5.72), (lx, YOUT - 0.1, -6.6), (lx, YOUT + 0.1, -6.6), (lx, YOUT + 0.1, -5.72)], "pipe:CHWR")
    return "data hall branches built"
