# Service equipment: a monorail beam and 2 ton manual chain hoist over each chiller's tube-pull zone,
# and the refrigerant pump-out station in the hall between CH-2 and CH-3 (storage receiver RS-1,
# pump-out unit PO-1, hoses, copper lines to CH-2/CH-3, a recovery cylinder, sign and floor outline).
# Re-runnable. Run inside Blender:
#   exec(open(os.path.expanduser("~/chiller-room/tools/pumpout_hoist.py")).read()); print(pumpout_hoist())

import bpy, bmesh, math, os
from mathutils import Vector, Matrix

exec(open(os.path.expanduser("~/chiller-room/tools/walkways.py")).read())   # web_mat, box, cyl, quad, B, new_obj...

BEAM_Z = -2.1                      # just south of the CWR header: the chains hang clear of every header
FLANGE_B, FLANGE_T = 5.25, 5.5     # under the bridges' frames (5.78)
BEAMS = {1: (-2.6, 9.2, 6.3), 2: (12.8, 25.0, 19.5), 3: (25.8, 37.6, 34.5)}   # x0, x1, where the hoist is parked
NO_HANGER = [(4.4, 6.1), (19.9, 21.9)]   # under the bridges: nothing may pass up through the deck

TX0, TX1, TY, TZ, TR = 22.4, 24.8, 0.78, 0.9, 0.45   # receiver shell


def mat(name, rgb, rough, metal, kind=0, emit=0):
    m = web_mat(name, rgb, rough, metal, kind)
    m["web_emit"] = emit
    return m


def prefix(n):
    return "" if n == 1 else f"CH-{n} "


def sphere(bm, c, r, scale=(1, 1, 1), seg=24):
    g = bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=seg // 2, radius=r)
    bmesh.ops.transform(bm, matrix=Matrix.Translation(B(*c)) @ Matrix.Diagonal((scale[0], scale[2], scale[1], 1)), verts=g["verts"])


def polyline(bm, pts, r, seg=8):
    for a, b in zip(pts, pts[1:]):
        cyl(bm, a, b, r, seg=seg)


def hose(bm, a, b, sag, r=0.012, n=10):
    """A flexible hose hanging between two room points."""
    pts = []
    for k in range(n + 1):
        t = k / n
        p = [a[i] + (b[i] - a[i]) * t for i in range(3)]
        p[1] -= sag * 4 * t * (1 - t)
        pts.append(tuple(p))
    polyline(bm, pts, r, seg=8)


def label_quad(name, pts, pick):
    """A label: pts are bottom-left, bottom-right, top-right, top-left as you read it."""
    bm = bmesh.new()
    bm.faces.new([bm.verts.new(B(*p)) for p in pts])
    new_obj(name, bm, bpy.data.materials["LB Label"], "Labels", smooth=False, props={"pick": pick})


def hoists():
    yellow = mat("SV Beam Yellow", (232, 178, 24), 0.45, 0.2)
    steel = mat("SV Steel", (70, 74, 80), 0.5, 0.6)
    red = mat("SV Hoist Red", (196, 46, 30), 0.4, 0.15)
    chain = mat("SV Chain", (52, 54, 56), 0.35, 0.85)
    for n, (x0, x1, hx) in BEAMS.items():
        pick = f"hoist:CH-{n}"
        z = BEAM_Z
        be, su, tr, ho, ch, hk = (bmesh.new() for _ in range(6))
        # The beam: bottom flange, web, top flange; end stops under the flange.
        box(be, x0, x1, FLANGE_B, FLANGE_B + 0.018, z - 0.1, z + 0.1)
        box(be, x0, x1, FLANGE_B + 0.018, FLANGE_T - 0.018, z - 0.006, z + 0.006)
        box(be, x0, x1, FLANGE_T - 0.018, FLANGE_T, z - 0.1, z + 0.1)
        for x in (x0 + 0.05, x1 - 0.05):
            box(su, x - 0.02, x + 0.02, FLANGE_B - 0.1, FLANGE_B, z - 0.1, z + 0.1)
        # Drop hangers to the roof steel, about every 4 m, never through a bridge.
        k = max(2, round((x1 - x0) / 4) + 1)
        for i in range(k):
            x = x0 + 0.35 + (x1 - x0 - 0.7) * i / (k - 1)
            for a, b in NO_HANGER:
                if a < x < b:
                    x = a if x - a < b - x else b
            box(su, x - 0.05, x + 0.05, FLANGE_T, 9.55, z - 0.05, z + 0.05)
            box(su, x - 0.15, x + 0.15, FLANGE_T, FLANGE_T + 0.02, z - 0.12, z + 0.12)
            box(su, x - 0.15, x + 0.15, 9.53, 9.55, z - 0.12, z + 0.12)
        # Trolley: side plates hugging the flange, four wheels on it, the load bar under it.
        for s in (-1, 1):
            box(tr, hx - 0.18, hx + 0.18, FLANGE_B - 0.16, FLANGE_B + 0.15, z + s * 0.14, z + s * 0.125)
            for dx in (-0.11, 0.11):
                cyl(tr, (hx + dx, FLANGE_B + 0.07, z + s * 0.035), (hx + dx, FLANGE_B + 0.07, z + s * 0.125), 0.05, seg=14, caps=True)
        box(tr, hx - 0.05, hx + 0.05, FLANGE_B - 0.17, FLANGE_B - 0.12, z - 0.14, z + 0.14)
        # Hoist: hook-on lug, gear housing, gear cover, hand wheel cover.
        cy = 4.72
        box(ho, hx - 0.03, hx + 0.03, cy + 0.15, FLANGE_B - 0.17, z - 0.02, z + 0.02)
        cyl(ho, (hx, cy, z - 0.11), (hx, cy, z + 0.11), 0.16, seg=24, caps=True)
        cyl(ho, (hx, cy, z - 0.11), (hx, cy, z - 0.16), 0.17, seg=24, caps=True)
        cyl(ho, (hx, cy - 0.01, z + 0.11), (hx, cy - 0.01, z + 0.17), 0.19, seg=24, caps=True)   # hand wheel, south side
        # Hand chain loop off the wheel, load chain down to the hook block, and a little slack chain.
        for dx in (-0.17, 0.17):
            cyl(ch, (hx + dx, cy - 0.05, z + 0.15), (hx + dx * 0.9, 1.3, z + 0.15), 0.007, seg=6)
        polyline(ch, [(hx - 0.153, 1.3, z + 0.15), (hx - 0.1, 1.22, z + 0.15), (hx + 0.1, 1.22, z + 0.15), (hx + 0.153, 1.3, z + 0.15)], 0.007, seg=6)
        cyl(ch, (hx - 0.03, cy - 0.15, z + 0.02), (hx - 0.03, 2.48, z + 0.02), 0.011, seg=6)
        polyline(ch, [(hx + 0.05, cy - 0.15, z + 0.02), (hx + 0.07, 3.9, z + 0.02), (hx + 0.12, 3.82, z + 0.02), (hx + 0.16, 3.9, z + 0.02), (hx + 0.12, cy - 0.15, z + 0.02)], 0.011, seg=6)
        # Hook block and hook.
        box(hk, hx - 0.09, hx + 0.03, 2.3, 2.48, z - 0.045, z + 0.085)
        cyl(ch, (hx - 0.03, 2.3, z + 0.02), (hx - 0.03, 2.2, z + 0.02), 0.022, seg=8)
        pts = [(hx - 0.03 + 0.075 * math.cos(math.radians(a)), 2.13 + 0.075 * math.sin(math.radians(a)), z + 0.02)
               for a in range(90, -205, -25)]
        polyline(ch, pts, 0.018, seg=8)
        p = prefix(n)
        props = {"pick": pick, "no_collide": True}
        for name, bm_, m in ((p + "Monorail Beam", be, yellow), (p + "Monorail Hangers and Stops", su, steel),
                             (p + "Hoist Trolley", tr, steel), (p + "Chain Hoist", ho, red), (p + "Hoist Chains", ch, chain),
                             (p + "Hoist Hook Block", hk, yellow)):
            new_obj(name, bm_, m, "Plant", smooth=name.endswith("Chain Hoist") or name.endswith("Chains"), props=props)
        # Capacity marking on both sides of the web, at the beam's middle.
        xm = (x0 + x1) / 2 + (1.5 if n == 1 else 0.0)
        y0, y1 = FLANGE_B + 0.035, FLANGE_T - 0.035
        label_quad(f"Label Rating {p}South".replace("  ", " "), [(xm - 0.75, y0, z + 0.008), (xm + 0.75, y0, z + 0.008), (xm + 0.75, y1, z + 0.008), (xm - 0.75, y1, z + 0.008)], pick)
        label_quad(f"Label Rating {p}North".replace("  ", " "), [(xm + 0.75, y0, z - 0.008), (xm - 0.75, y0, z - 0.008), (xm - 0.75, y1, z - 0.008), (xm + 0.75, y1, z - 0.008)], pick)


def pumpout():
    tank_m = mat("SV Receiver Gray", (206, 206, 198), 0.45, 0.2)
    steel = mat("SV Steel", (70, 74, 80), 0.5, 0.6)
    brass = mat("SV Brass", (196, 160, 70), 0.3, 0.9)
    copper = mat("SV Copper", (186, 112, 64), 0.3, 0.9)
    vent = mat("SV Vent Yellow", (230, 180, 30), 0.45, 0.2)
    glass = mat("SV Sight Glass", (150, 190, 200), 0.05, 0.0, kind=5)
    unit_m = mat("SV Unit Blue", (40, 86, 140), 0.45, 0.3)
    black = mat("SV Black", (26, 28, 30), 0.5, 0.3)
    coil = mat("SV Coil", (90, 96, 100), 0.6, 0.6)
    panel = mat("SV Panel Gray", (196, 200, 204), 0.5, 0.2)
    gauge = mat("SV Gauge Face", (236, 236, 230), 0.4, 0.0)
    hose_r = mat("SV Hose Red", (180, 30, 28), 0.6, 0.0)
    hose_b = mat("SV Hose Blue", (30, 70, 170), 0.6, 0.0)
    hose_y = mat("SV Hose Yellow", (220, 180, 30), 0.6, 0.0)
    cyl_gray = mat("SV Cylinder Gray", (150, 154, 156), 0.45, 0.4)
    green_led = mat("SV LED Green", (40, 230, 90), 0.4, 0.0, emit=1)
    stripe = bpy.data.materials["RM Safety Stripe"]

    tk, sd, ft, vl, gl, vp = (bmesh.new() for _ in range(6))
    # Receiver: shell, elliptical heads, saddles, liquid/vapour valves, relief valves and vent, sight glass.
    cyl(tk, (TX0, TY, TZ), (TX1, TY, TZ), TR, seg=40)
    for x in (TX0, TX1):
        sphere(tk, (x, TY, TZ), TR, scale=(0.5, 1, 1), seg=32)
    for x in (TX0 + 0.5, TX1 - 0.5):
        box(sd, x - 0.13, x + 0.13, 0.0, 0.03, TZ - 0.42, TZ + 0.42)
        box(sd, x - 0.012, x + 0.012, 0.03, TY - 0.15, TZ - 0.38, TZ + 0.38)
        box(sd, x - 0.08, x + 0.08, TY - 0.32, TY - 0.28, TZ - 0.36, TZ + 0.36)
    top = TY + TR
    for x, wheel in ((23.25, hose_b), (23.9, hose_r)):
        cyl(ft, (x, top - 0.02, TZ), (x, top + 0.07, TZ), 0.025, seg=10)
        box(vl, x - 0.045, x + 0.045, top + 0.07, top + 0.16, TZ - 0.045, TZ + 0.045)
        cyl(vl, (x, top + 0.115, TZ + 0.045), (x, top + 0.115, TZ + 0.1), 0.018, seg=8, caps=True)   # side port
        cyl(vl, (x, top + 0.16, TZ), (x, top + 0.2, TZ), 0.01, seg=6)
        hw = bmesh.new(); cyl(hw, (x, top + 0.2, TZ), (x, top + 0.215, TZ), 0.055, seg=16, caps=True)
        new_obj(f"Receiver Valve Wheel {x:.2f}", hw, wheel, "Plant", smooth=False, props={"pick": "receiver:RS-1", "no_collide": True})
    rx = 24.45
    cyl(ft, (rx, top - 0.02, TZ), (rx, top + 0.08, TZ), 0.03, seg=10)
    box(vl, rx - 0.12, rx + 0.12, top + 0.08, top + 0.16, TZ - 0.05, TZ + 0.05)   # three-way valve
    for dx in (-0.08, 0.08):
        cyl(vl, (rx + dx, top + 0.16, TZ), (rx + dx, top + 0.32, TZ), 0.035, seg=12, caps=True)
        cyl(vp, (rx + dx, top + 0.32, TZ), (rx + dx, top + 0.42, TZ), 0.02, seg=8)
    polyline(vp, [(rx - 0.08, top + 0.42, TZ), (rx + 0.08, top + 0.42, TZ)], 0.022, seg=8)
    cyl(vp, (rx, top + 0.42, TZ), (rx, 9.95, TZ), 0.03, seg=10)
    for y in (3.5, 6.5, 9.0):
        box(sd, rx - 0.04, rx + 0.04, y, y + 0.04, TZ - 0.04, TZ + 0.04)   # guide clamps
    gx = TX0 - 0.17
    for y in (TY - 0.33, TY + 0.33):
        cyl(ft, (TX0 - 0.1, y, TZ + 0.25), (gx, y, TZ + 0.25), 0.015, seg=8)
    cyl(gl, (gx, TY - 0.33, TZ + 0.25), (gx, TY + 0.33, TZ + 0.25), 0.02, seg=10, caps=True)
    for y in (TY - 0.36, TY + 0.36):
        cyl(ft, (gx, y - 0.03, TZ + 0.25), (gx, y + 0.03, TZ + 0.25), 0.03, seg=10, caps=True)
    props_r = {"pick": "receiver:RS-1"}
    new_obj("Refrigerant Receiver", tk, tank_m, "Plant", smooth=True, props=props_r)
    new_obj("Receiver Saddles and Clamps", sd, steel, "Plant", smooth=False, props=props_r)
    new_obj("Receiver Fittings", ft, brass, "Plant", smooth=True, props=dict(props_r, no_collide=True))
    new_obj("Receiver Valves", vl, brass, "Plant", smooth=False, props=dict(props_r, no_collide=True))
    new_obj("Receiver Sight Glass", gl, glass, "Plant", smooth=True, props=dict(props_r, no_collide=True))
    new_obj("Receiver Relief Vent", vp, vent, "Plant", smooth=True, props=dict(props_r, no_collide=True))
    label_quad("Label Tag RS-1", [(23.35, TY - 0.09, TZ + TR + 0.006), (23.85, TY - 0.09, TZ + TR + 0.006),
                                  (23.85, TY + 0.09, TZ + TR + 0.006), (23.35, TY + 0.09, TZ + TR + 0.006)], "receiver:RS-1")

    # Pump-out unit PO-1 east of the receiver: base frame, compressor, condenser and fan, control box.
    ux0, ux1, uz0, uz1 = 25.25, 26.35, 0.25, 1.05
    fr, cp, co, cb, gf, ld, hs_r, hs_b, hs_y, cu = (bmesh.new() for _ in range(10))
    for z in (uz0, uz1 - 0.08):
        box(fr, ux0, ux1, 0.0, 0.08, z, z + 0.08)
    for x in (ux0, ux1 - 0.08):
        box(fr, x, x + 0.08, 0.0, 0.08, uz0, uz1)
    box(fr, ux0 + 0.02, ux0 + 0.06, 0.08, 1.3, uz1 - 0.06, uz1 - 0.02)   # upright for the control box
    cyl(cp, (25.55, 0.1, 0.62), (25.55, 0.5, 0.62), 0.17, seg=24)
    sphere(cp, (25.55, 0.5, 0.62), 0.17, scale=(1, 0.55, 1), seg=24)
    box(fr, 25.35, 25.75, 0.08, 0.11, 0.42, 0.82)
    cyl(cp, (25.85, 0.12, 0.4), (25.85, 0.62, 0.4), 0.06, seg=14, caps=True)   # oil separator
    box(co, 25.98, 26.3, 0.1, 0.82, uz0 + 0.03, uz1 - 0.03)
    cyl(cb, (26.305, 0.46, 0.65), (26.33, 0.46, 0.65), 0.3, seg=28)   # fan guard ring
    for a in range(0, 180, 30):
        r = math.radians(a)
        cyl(cb, (26.33, 0.46 + 0.29 * math.cos(r), 0.65 + 0.29 * math.sin(r)), (26.33, 0.46 - 0.29 * math.cos(r), 0.65 - 0.29 * math.sin(r)), 0.006, seg=4)
    cyl(cb, (26.3, 0.46, 0.65), (26.34, 0.46, 0.65), 0.05, seg=12, caps=True)
    # Control box with a selector, pilot light and two gauges, facing south.
    box(cb, ux0 + 0.06, 25.85, 0.85, 1.3, uz1 - 0.12, uz1 - 0.02)
    cyl(cb, (25.42, 1.18, uz1 - 0.02), (25.42, 1.18, uz1 + 0.01), 0.025, seg=10, caps=True)
    cyl(ld, (25.5, 1.18, uz1 - 0.02), (25.5, 1.18, uz1 + 0.005), 0.012, seg=8, caps=True)
    for x in (25.58, 25.74):
        cyl(cb, (x, 1.0, uz1 - 0.02), (x, 1.0, uz1 + 0.01), 0.055, seg=18, caps=True)
        cyl(gf, (x, 1.0, uz1 + 0.01), (x, 1.0, uz1 + 0.014), 0.046, seg=18, caps=True)
    # Hoses from the receiver valves to the unit, and a yellow one coiled on the frame.
    # Over the top of the shell and down past its east head to the unit.
    for hb, x, zz, mid, end in ((hs_b, 23.25, 1.06, (25.12, 1.05, 0.98), (25.5, 0.62, uz0 + 0.1)),
                                (hs_r, 23.9, 1.1, (25.2, 1.05, 0.82), (25.85, 0.58, uz0 + 0.13))):
        polyline(hb, [(x, top + 0.115, TZ + 0.1), (x + 0.12, top + 0.13, zz), (24.75, top + 0.07, zz), mid], 0.012)
        hose(hb, mid, end, 0.08)
    for k in range(3):
        rr = 0.14 - k * 0.012
        pts = [(ux0 - 0.05, 0.75 + rr * math.sin(math.radians(a)), uz1 - 0.3 + rr * math.cos(math.radians(a))) for a in range(0, 361, 30)]
        polyline(hs_y, pts, 0.011, seg=6)
    # Permanent copper lines: up from the unit, north, then to CH-3 and CH-2, each ending at a ball valve.
    up = (25.7, 2.9, uz1 - 0.05)
    polyline(cu, [(25.7, 1.3, uz1 - 0.05), up, (25.7, 2.9, -1.7)], 0.016, seg=8)
    polyline(cu, [(25.7, 2.9, -1.7), (26.7, 2.9, -1.7), (26.7, 1.3, -1.7), (26.7, 1.3, -2.08)], 0.016, seg=8)
    polyline(cu, [(25.7, 2.9, -1.7), (17.4, 2.9, -1.7), (17.4, 1.3, -1.7), (17.4, 1.3, -2.08)], 0.016, seg=8)
    bv, hg = bmesh.new(), bmesh.new()
    for x in (26.7, 17.4):
        box(bv, x - 0.04, x + 0.04, 1.26, 1.34, -1.95, -1.87)
        box(bv, x - 0.01, x + 0.01, 1.34, 1.37, -1.99, -1.83)
    for x, z in ((25.7, -0.3), (23.0, -1.7), (19.4, -1.7)):
        cyl(hg, (x, 2.92, z), (x, 9.55, z), 0.008, seg=6)
        box(hg, x - 0.05, x + 0.05, 2.86, 2.88, z - 0.04, z + 0.04)
    new_obj("Pump-Out Line Valves", bv, brass, "Plant", smooth=False, props={"pick": "pumpout:PO-1", "no_collide": True})
    new_obj("Pump-Out Line Hangers", hg, steel, "Plant", smooth=False, props={"pick": "pumpout:PO-1", "no_collide": True})
    props_u = {"pick": "pumpout:PO-1"}
    for name, bm_, m, coll in (("Pump-Out Frame", fr, steel, True), ("Pump-Out Compressor", cp, black, True),
                               ("Pump-Out Condenser Coil", co, coil, True), ("Pump-Out Unit Panels", cb, unit_m, True),
                               ("Pump-Out Gauge Faces White", gf, gauge, False), ("Pump-Out Pilot Light", ld, green_led, False),
                               ("Pump-Out Hose Red", hs_r, hose_r, False), ("Pump-Out Hose Blue", hs_b, hose_b, False),
                               ("Pump-Out Hose Yellow", hs_y, hose_y, False), ("Pump-Out Copper Lines", cu, copper, False)):
        new_obj(name, bm_, m, "Plant", smooth=name.startswith("Pump-Out Hose") or name.endswith("Lines") or name.endswith("Compressor"),
                props=props_u if coll else dict(props_u, no_collide=True))

    # A recovery cylinder (gray, yellow shoulder) on a hand truck, west of the receiver.
    cx, cz = 21.95, 0.35
    ht, rc, rt = bmesh.new(), bmesh.new(), bmesh.new()
    for dz in (-0.17, 0.17):
        cyl(ht, (cx - 0.16, 0.12, cz + dz - 0.03), (cx - 0.16, 0.12, cz + dz + 0.03), 0.12, seg=16, caps=True)
        cyl(ht, (cx - 0.2, 0.08, cz + dz * 0.8), (cx - 0.2, 1.15, cz + dz * 0.8), 0.014, seg=8)
    cyl(ht, (cx - 0.16, 0.12, cz - 0.2), (cx - 0.16, 0.12, cz + 0.2), 0.012, seg=6)
    cyl(ht, (cx - 0.2, 1.15, cz - 0.14), (cx - 0.2, 1.15, cz + 0.14), 0.014, seg=8)
    box(ht, cx - 0.21, cx + 0.12, 0.04, 0.06, cz - 0.15, cz + 0.15)
    cyl(rc, (cx - 0.04, 0.06, cz), (cx - 0.04, 0.62, cz), 0.15, seg=24, caps=True)
    sphere(rt, (cx - 0.04, 0.62, cz), 0.15, scale=(1, 0.6, 1), seg=24)
    cyl(rt, (cx - 0.04, 0.7, cz), (cx - 0.04, 0.8, cz), 0.025, seg=10, caps=True)
    cyl(rt, (cx - 0.04, 0.72, cz), (cx - 0.04, 0.82, cz), 0.07, seg=16)   # collar
    props_c = {"pick": "pumpout:PO-1"}
    new_obj("Recovery Cylinder Hand Truck", ht, black, "Plant", smooth=False, props=props_c)
    new_obj("Recovery Cylinder", rc, cyl_gray, "Plant", smooth=True, props=props_c)
    new_obj("Recovery Cylinder Shoulder", rt, hose_y, "Plant", smooth=True, props=dict(props_c, no_collide=True))

    # Sign on a stand facing west (toward the plant room), and a yellow floor outline round the station.
    sg, fl = bmesh.new(), bmesh.new()
    sx, sz = 21.75, 1.6
    cyl(sg, (sx + 0.03, 0.0, sz), (sx + 0.03, 1.62, sz), 0.022, seg=8)
    box(sg, sx - 0.2, sx + 0.2, 0.0, 0.02, sz - 0.2, sz + 0.2)
    box(sg, sx + 0.005, sx + 0.015, 1.22, 1.6, sz - 0.25, sz + 0.25)
    new_obj("Pump-Out Sign Stand", sg, steel, "Plant", smooth=False, props=props_u)
    label_quad("Label Sign Pump-Out", [(sx, 1.24, sz - 0.24), (sx, 1.24, sz + 0.24), (sx, 1.58, sz + 0.24), (sx, 1.58, sz - 0.24)], "pumpout:PO-1")
    x0, x1, z0, z1, w, h = 21.5, 26.75, -0.45, 1.95, 0.08, 0.004
    for a, b, c, d in ((x0, x1, z0, z0 + w), (x0, x1, z1 - w, z1), (x0, x0 + w, z0, z1), (x1 - w, x1, z0, z1)):
        box(fl, a, b, 0.0, h, c, d)
    new_obj("Pump-Out Floor Outline", fl, stripe, "Plant", smooth=False, props={"pick": "pass", "no_collide": True})


def pumpout_hoist():
    for ob in [o for o in bpy.data.objects if o.name.startswith("Receiver Valve Wheel")]:
        bpy.data.objects.remove(ob, do_unlink=True)
    hoists()
    pumpout()
    return "pump-out station and hoists built"
