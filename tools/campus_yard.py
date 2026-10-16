# The fenced utility yard between the service road and Data Hall 01: two standby diesel generators
# on belly fuel tanks, two pad-mounted transformers and medium-voltage switchgear, a chain-link fence
# with barbed wire and a double gate, yard lights and bollards. Outdoor kind 12; param 7 is chain-link
# fabric (room.wgsl draws it see-through). Collection "Yard". Re-runnable:
#   exec(open(os.path.expanduser("~/chiller-room/tools/campus_yard.py")).read()); print(campus_yard())

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/data_hall.py")).read())   # out_mat, front_quad, box, cyl, quad, B, new_obj...

FX0, FX1, FZS, FZN = -18.0, 23.0, -25.9, -33.1   # fence: west, east, south (road side), north
FH = 2.4                                          # fabric height; barbed wire above
GATE = (12.5, 16.5)                               # double gate in the south run
GENS = ((-16.0, -9.5, "GEN-1"), (-7.5, -1.0, "GEN-2"))
GZ0, GZ1 = -30.8, -28.2                           # generator enclosure depth (z)
TXS = ((11.0, 13.2, "TX-1"), (14.8, 17.0, "TX-2"))
TZ0, TZ1 = -30.4, -28.4


def outdoor_label(name, pts, lit=False):
    bm = bmesh.new()
    bm.faces.new([bm.verts.new(B(*p)) for p in pts])
    new_obj(name, bm, bpy.data.materials["LB Label Lit" if lit else "LB Label"], "Labels", smooth=False, props={"pick": "pass"})


def campus_yard():
    concrete = out_mat("YD Concrete", (168, 166, 160), 0.9, 0.0, 2)
    gen_m = out_mat("CY Generator Enclosure", (206, 199, 178), 0.45, 0.2, 4)
    tank = out_mat("CY Fuel Tank", (58, 62, 66), 0.5, 0.4, 0)
    louvre = out_mat("DH Louvre", (120, 126, 130), 0.5, 0.5, 5)
    exhaust = out_mat("CY Exhaust Black", (34, 34, 36), 0.6, 0.5, 0)
    door = out_mat("CY Enclosure Door", (190, 183, 162), 0.45, 0.2, 0)
    tx_m = out_mat("CY Transformer Green", (66, 96, 74), 0.45, 0.3, 0)
    gear = out_mat("CY Switchgear Gray", (170, 176, 180), 0.45, 0.3, 0)
    galv = out_mat("YD Galvanized Plain", (165, 170, 173), 0.5, 0.5, 0)
    fabric = out_mat("CY Chain Link", (150, 156, 160), 0.5, 0.6, 7)
    yellow = out_mat("YD Rail Yellow", (232, 178, 24), 0.45, 0.2, 0)
    pole = out_mat("CY Light Pole", (96, 100, 106), 0.45, 0.5, 0)
    hw = out_mat("DH Trim", (90, 96, 104), 0.45, 0.6, 0)

    cn, gn, tk, lv, ex, dr, tx, sg, ps, fb, yl, lp, hd = (bmesh.new() for _ in range(13))

    # Generators: pad, belly fuel tank, enclosure, side doors, radiator louvre (east end), intake louvre,
    # roof silencer and stack with a rain cap, a fuel fill box.
    for x0, x1, tag in GENS:
        box(cn, x0 - 0.5, x1 + 0.5, 0.0, 0.15, GZ0 - 0.6, GZ1 + 0.6)
        box(tk, x0 - 0.1, x1 + 0.1, 0.15, 0.95, GZ0 - 0.1, GZ1 + 0.1)
        box(gn, x0, x1, 0.95, 4.1, GZ0, GZ1)
        for k in range(3):
            dx = x0 + 0.6 + k * 1.6
            box(dr, dx, dx + 1.2, 1.15, 3.6, GZ1, GZ1 + 0.03)
            box(hd, dx + 1.0, dx + 1.08, 2.2, 2.4, GZ1 + 0.03, GZ1 + 0.07)
        quad(lv, [(x1 + 0.02, 1.2, GZ1 - 0.2), (x1 + 0.02, 1.2, GZ0 + 0.2), (x1 + 0.02, 3.85, GZ0 + 0.2), (x1 + 0.02, 3.85, GZ1 - 0.2)])
        front_quad(lv, x1 - 1.6, x1 - 0.3, 1.4, 3.6, GZ1 + 0.02)
        cyl(ex, (x0 + 1.0, 4.55, (GZ0 + GZ1) / 2), (x0 + 3.6, 4.55, (GZ0 + GZ1) / 2), 0.38, seg=20, caps=True)
        for x in (x0 + 1.4, x0 + 3.2):
            box(ex, x - 0.05, x + 0.05, 4.1, 4.2, GZ0 + 0.9, GZ1 - 0.9)
        sx = x0 + 3.4
        cyl(ex, (sx, 4.55, (GZ0 + GZ1) / 2), (sx, 5.9, (GZ0 + GZ1) / 2), 0.18, seg=16)
        box(ex, sx - 0.2, sx + 0.2, 5.9, 5.94, (GZ0 + GZ1) / 2 - 0.2, (GZ0 + GZ1) / 2 + 0.2)   # rain cap
        box(tk, x0 + 0.3, x0 + 0.8, 0.5, 0.85, GZ1 + 0.1, GZ1 + 0.3)   # fuel fill box
        outdoor_label(f"Label Tag {tag}", [(x1 - 2.3, 3.75, GZ1 + 0.035), (x1 - 1.7, 3.75, GZ1 + 0.035),
                                           (x1 - 1.7, 3.95, GZ1 + 0.035), (x1 - 2.3, 3.95, GZ1 + 0.035)])
    # Transformers: pad, tank with front doors, cooling fins on the back, a DANGER sign.
    for x0, x1, tag in TXS:
        box(cn, x0 - 0.4, x1 + 0.4, 0.0, 0.15, TZ0 - 0.7, TZ1 + 0.4)
        box(tx, x0, x1, 0.15, 1.95, TZ0, TZ1)
        box(tx, x0 + 0.05, x1 - 0.05, 1.95, 2.0, TZ0 + 0.05, TZ1 - 0.05)
        for dx0, dx1 in ((x0 + 0.08, (x0 + x1) / 2 - 0.02), ((x0 + x1) / 2 + 0.02, x1 - 0.08)):
            box(tx, dx0, dx1, 0.25, 1.85, TZ1, TZ1 + 0.03)
        box(hd, (x0 + x1) / 2 - 0.05, (x0 + x1) / 2 + 0.05, 1.0, 1.2, TZ1 + 0.03, TZ1 + 0.08)   # hasp
        x = x0 + 0.15
        while x < x1 - 0.1:
            box(tx, x - 0.012, x + 0.012, 0.35, 1.6, TZ0 - 0.45, TZ0)
            x += 0.12
        outdoor_label(f"Label Tag {tag}", [(x0 + 0.15, 1.55, TZ1 + 0.035), (x0 + 0.75, 1.55, TZ1 + 0.035),
                                           (x0 + 0.75, 1.75, TZ1 + 0.035), (x0 + 0.15, 1.75, TZ1 + 0.035)])
        outdoor_label(f"Label Sign High Voltage {tag}", [(x1 - 0.65, 1.3, TZ1 + 0.035), (x1 - 0.15, 1.3, TZ1 + 0.035),
                                                         (x1 - 0.15, 1.66, TZ1 + 0.035), (x1 - 0.65, 1.66, TZ1 + 0.035)])
    # Medium-voltage switchgear beside them.
    box(cn, 18.6, 22.2, 0.0, 0.15, TZ0 - 0.4, TZ1 + 0.6)
    box(sg, 19.0, 21.8, 0.15, 2.45, TZ0, TZ1)
    box(sg, 18.9, 21.9, 2.45, 2.55, TZ0 - 0.1, TZ1 + 0.15)
    for k in range(3):
        dx = 19.08 + k * 0.92
        box(hd, dx, dx + 0.84, 0.3, 2.3, TZ1, TZ1 + 0.02)
        box(hd, dx + 0.7, dx + 0.76, 1.2, 1.4, TZ1 + 0.02, TZ1 + 0.06)
    # Bollards in front of the generators and transformers.
    for x in (-16.3, -9.2, -7.8, -0.7, 10.6, 13.6, 14.4, 17.4):
        cyl(yl, (x, 0.0, -27.2), (x, 1.1, -27.2), 0.1, seg=12, caps=True)

    # Fence: posts every 3 m (stout at corners and the gate), top rail, bottom wire, barbed-wire arms.
    runs = [((FX0, FZS), (GATE[0], FZS)), ((GATE[1], FZS), (FX1, FZS)), ((FX1, FZS), (FX1, FZN)),
            ((FX1, FZN), (FX0, FZN)), ((FX0, FZN), (FX0, FZS))]
    for (ax, az), (bx, bz) in runs:
        L = math.hypot(bx - ax, bz - az)
        n = max(1, round(L / 3.0))
        for k in range(n + 1):
            t = k / n
            x, z = ax + (bx - ax) * t, az + (bz - az) * t
            r = 0.06 if k in (0, n) else 0.04
            cyl(ps, (x, 0.0, z), (x, FH + 0.05, z), r, seg=10, caps=True)
            # Arm leaning out (away from the yard) for the barbed wire.
            ox, oz = (0.0, 1.0) if az == FZS and bz == FZS else (0.0, -1.0) if az == FZN and bz == FZN else (1.0 if ax == FX1 else -1.0, 0.0)
            cyl(ps, (x, FH + 0.05, z), (x + ox * 0.3, FH + 0.35, z + oz * 0.3), 0.012, seg=6)
        for y, rr in ((FH, 0.025), (0.1, 0.006)):
            cyl(ps, (ax, y, az), (bx, y, bz), rr, seg=8)
        for j in range(1, 4):
            ox, oz = (0.0, 1.0) if az == FZS and bz == FZS else (0.0, -1.0) if az == FZN and bz == FZN else (1.0 if ax == FX1 else -1.0, 0.0)
            f = j / 3
            cyl(ps, (ax + ox * 0.3 * f, FH + 0.05 + 0.3 * f, az + oz * 0.3 * f), (bx + ox * 0.3 * f, FH + 0.05 + 0.3 * f, bz + oz * 0.3 * f), 0.005, seg=4)
        quad(fb, [(ax, 0.05, az), (bx, 0.05, bz), (bx, FH, bz), (ax, FH, az)])
    # The double gate: two framed leaves with fabric.
    g0, g1 = GATE
    mid = (g0 + g1) / 2
    for a, b in ((g0 + 0.08, mid - 0.03), (mid + 0.03, g1 - 0.08)):
        for y in (0.1, FH - 0.05):
            cyl(ps, (a, y, FZS), (b, y, FZS), 0.025, seg=8)
        for x in (a, b):
            cyl(ps, (x, 0.1, FZS), (x, FH - 0.05, FZS), 0.025, seg=8)
        cyl(ps, (a, 0.1, FZS), (b, FH - 0.05, FZS), 0.015, seg=6)
        quad(fb, [(a, 0.1, FZS), (b, 0.1, FZS), (b, FH - 0.05, FZS), (a, FH - 0.05, FZS)])
    for x in (g0, g1):
        cyl(ps, (x, 0.0, FZS), (x, FH + 0.15, FZS), 0.07, seg=12, caps=True)
    outdoor_label("Label Sign Yard Gate", [(g0 - 0.9, 1.2, FZS + 0.03), (g0 - 0.15, 1.2, FZS + 0.03),
                                           (g0 - 0.15, 1.7, FZS + 0.03), (g0 - 0.9, 1.7, FZS + 0.03)])

    # Yard lights: poles with an arm and an LED head, on concrete bases.
    for x in (-12.0, 19.0):
        z = -26.6
        box(cn, x - 0.3, x + 0.3, 0.0, 0.6, z - 0.3, z + 0.3)
        cyl(lp, (x, 0.6, z), (x, 8.0, z), 0.08, seg=12)
        cyl(lp, (x, 7.9, z), (x, 7.95, z - 1.1), 0.04, seg=8)
        box(lp, x - 0.18, x + 0.18, 7.82, 7.95, z - 1.5, z - 0.95)

    props = {"no_collide": True, "pick": "pass"}
    for name, bm_, m in (("Yard Pads", cn, concrete), ("Generator Enclosures", gn, gen_m), ("Generator Fuel Tanks", tk, tank),
                         ("Generator Louvres", lv, louvre), ("Generator Exhausts", ex, exhaust), ("Generator Doors", dr, door),
                         ("Transformers", tx, tx_m), ("Switchgear", sg, gear), ("Fence Posts and Wire", ps, galv),
                         ("Fence Fabric", fb, fabric), ("Yard Bollards", yl, yellow), ("Yard Light Poles", lp, pole),
                         ("Yard Hardware", hd, hw)):
        new_obj(name, bm_, m, YARD, smooth=name in ("Generator Exhausts", "Yard Bollards", "Yard Light Poles"), props=props)
    return "utility yard built"
